defmodule TaxiBeWeb.TaxiAllocationJobTest do
  use ExUnit.Case, async: false

  alias TaxiBeWeb.TaxiAllocationJob

  setup do
    previous_config = %{
      driver_response_timeout_ms: Application.get_env(:taxi_be, :driver_response_timeout_ms),
      taxi_arrival_ms: Application.get_env(:taxi_be, :taxi_arrival_ms),
      cancellation_penalty_window_ms:
        Application.get_env(:taxi_be, :cancellation_penalty_window_ms),
      cancellation_fee: Application.get_env(:taxi_be, :cancellation_fee)
    }

    Application.put_env(:taxi_be, :driver_response_timeout_ms, 10)
    Application.put_env(:taxi_be, :taxi_arrival_ms, 300_000)
    Application.put_env(:taxi_be, :cancellation_penalty_window_ms, 180_000)
    Application.put_env(:taxi_be, :cancellation_fee, 20)

    on_exit(fn ->
      Enum.each(previous_config, fn {key, value} ->
        Application.put_env(:taxi_be, key, value)
      end)
    end)

    TaxiBeWeb.Endpoint.subscribe("customer:galadriel")
    TaxiBeWeb.Endpoint.subscribe("driver:frodo")
    TaxiBeWeb.Endpoint.subscribe("driver:samwise")
    TaxiBeWeb.Endpoint.subscribe("driver:pippin")

    :ok
  end

  test "contacts all three drivers simultaneously" do
    assert {:noreply, state} =
             TaxiAllocationJob.handle_info(
               {:contact_taxis, taxis()},
               initial_state()
             )

    assert map_size(state.contacted_taxis) == 3
    assert is_reference(state.response_timer_ref)

    for driver <- ["frodo", "samwise", "pippin"] do
      assert_receive %Phoenix.Socket.Broadcast{
        topic: "driver:" <> ^driver,
        event: "booking_request",
        payload: %{bookingId: "booking-123"}
      }
    end

    Process.cancel_timer(state.response_timer_ref)
  end

  test "the first driver to accept wins" do
    timer_ref = Process.send_after(self(), :unexpected_timeout, 1_000)
    state = active_state(timer_ref)

    assert {:noreply, state} =
             TaxiAllocationJob.handle_info({:step2, "accept", "samwise"}, state)

    assert Process.read_timer(timer_ref) == false
    assert state.phase == :allocated
    assert state.accepted_driver.nickname == "samwise"
    assert is_reference(state.arrival_timer_ref)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:galadriel",
      payload: %{msg: message}
    }

    assert message =~ "samwise aceptó"
    Process.cancel_timer(state.arrival_timer_ref)
  end

  test "three rejections end the search before the timeout" do
    timer_ref = Process.send_after(self(), :unexpected_timeout, 1_000)
    state = active_state(timer_ref)

    assert {:noreply, state} =
             TaxiAllocationJob.handle_info({:step2, "reject", "frodo"}, state)

    assert {:noreply, state} =
             TaxiAllocationJob.handle_info({:step2, "reject", "samwise"}, state)

    assert {:stop, :normal, _state} =
             TaxiAllocationJob.handle_info({:step2, "reject", "pippin"}, state)

    assert Process.read_timer(timer_ref) == false

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:galadriel",
      payload: %{msg: message}
    }

    assert message =~ "ningún conductor aceptó"
  end

  test "notifies the customer when the group timeout expires" do
    state = active_state(make_ref())

    assert {:stop, :normal, state} =
             TaxiAllocationJob.handle_info(
               {:driver_group_timeout, "booking-123"},
               state
             )

    assert state.response_timer_ref == nil

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:galadriel",
      payload: %{msg: message}
    }

    assert message =~ "ningún conductor aceptó"
  end

  test "customer cancellation before allocation has no fee" do
    timer_ref = Process.send_after(self(), :unexpected_timeout, 1_000)
    state = active_state(timer_ref)

    assert {:stop, :normal, _state} =
             TaxiAllocationJob.handle_info({:cancel, "galadriel"}, state)

    assert Process.read_timer(timer_ref) == false

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:galadriel",
      event: "booking_closed",
      payload: %{msg: message}
    }

    assert message == "Viaje cancelado sin cargo."
  end

  test "customer cancellation with more than three minutes remaining has no fee" do
    state = allocated_state(240_000)

    assert {:stop, :normal, _state} =
             TaxiAllocationJob.handle_info({:cancel, "galadriel"}, state)

    assert Process.read_timer(state.arrival_timer_ref) == false

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:galadriel",
      event: "booking_closed",
      payload: %{msg: message}
    }

    assert message == "Viaje cancelado sin cargo."
  end

  test "customer cancellation within three minutes of arrival charges twenty dollars" do
    state = allocated_state(120_000)

    assert {:stop, :normal, _state} =
             TaxiAllocationJob.handle_info({:cancel, "galadriel"}, state)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:galadriel",
      event: "booking_closed",
      payload: %{msg: message}
    }

    assert message == "Viaje cancelado. Se aplicó un cargo de $20."

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "driver:frodo",
      event: "booking_cancelled",
      payload: %{msg: driver_message}
    }

    assert driver_message =~ "Cargo aplicado: $20"
  end

  test "taxi arrival archives the active booking" do
    state = allocated_state(120_000)

    assert {:stop, :normal, _state} =
             TaxiAllocationJob.handle_info(
               {:taxi_arrived, "booking-123"},
               state
             )

    Process.cancel_timer(state.arrival_timer_ref)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:galadriel",
      event: "booking_closed",
      payload: %{msg: message}
    }

    assert message =~ "frodo llegó"
  end

  defp initial_state do
    %{
      request: request(),
      phase: :searching,
      contacted_taxis: %{},
      rejected_drivers: MapSet.new(),
      response_timer_ref: nil,
      accepted_driver: nil,
      arrival_timer_ref: nil,
      arrival_deadline_ms: nil
    }
  end

  defp active_state(timer_ref) do
    %{
      request: request(),
      phase: :searching,
      contacted_taxis: Map.new(taxis(), &{&1.nickname, &1}),
      rejected_drivers: MapSet.new(),
      response_timer_ref: timer_ref,
      accepted_driver: nil,
      arrival_timer_ref: nil,
      arrival_deadline_ms: nil
    }
  end

  defp allocated_state(remaining_ms) do
    arrival_timer_ref = Process.send_after(self(), :unexpected_arrival, 300_000)

    %{
      request: request(),
      phase: :allocated,
      contacted_taxis: Map.new(taxis(), &{&1.nickname, &1}),
      rejected_drivers: MapSet.new(),
      response_timer_ref: nil,
      accepted_driver: %{nickname: "frodo"},
      arrival_timer_ref: arrival_timer_ref,
      arrival_deadline_ms: System.monotonic_time(:millisecond) + remaining_ms
    }
  end

  defp taxis do
    [
      %{nickname: "frodo"},
      %{nickname: "samwise"},
      %{nickname: "pippin"}
    ]
  end

  defp request do
    %{
      "pickup_address" => "Tec",
      "dropoff_address" => "Animas",
      "booking_id" => "booking-123",
      "username" => "galadriel"
    }
  end
end
