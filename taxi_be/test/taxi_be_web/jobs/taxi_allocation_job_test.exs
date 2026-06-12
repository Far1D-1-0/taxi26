defmodule TaxiBeWeb.TaxiAllocationJobTest do
  use ExUnit.Case, async: false

  alias TaxiBeWeb.TaxiAllocationJob

  setup do
    previous_timeout = Application.get_env(:taxi_be, :driver_response_timeout_ms)
    Application.put_env(:taxi_be, :driver_response_timeout_ms, 10)

    on_exit(fn ->
      Application.put_env(:taxi_be, :driver_response_timeout_ms, previous_timeout)
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

    assert {:stop, :normal, _state} =
             TaxiAllocationJob.handle_info({:step2, "accept", "samwise"}, state)

    assert Process.read_timer(timer_ref) == false

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:galadriel",
      payload: %{msg: message}
    }

    assert message =~ "samwise aceptó"
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

  defp initial_state do
    %{
      request: request(),
      contacted_taxis: %{},
      rejected_drivers: MapSet.new(),
      response_timer_ref: nil
    }
  end

  defp active_state(timer_ref) do
    %{
      request: request(),
      contacted_taxis: Map.new(taxis(), &{&1.nickname, &1}),
      rejected_drivers: MapSet.new(),
      response_timer_ref: timer_ref
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
