defmodule TaxiBeWeb.TaxiAllocationJobTest do
  use ExUnit.Case, async: false

  alias TaxiBeWeb.TaxiAllocationJob

  setup do
    previous_timeout = Application.get_env(:taxi_be, :driver_response_timeout_ms)
    Application.put_env(:taxi_be, :driver_response_timeout_ms, 10)

    on_exit(fn ->
      if previous_timeout do
        Application.put_env(:taxi_be, :driver_response_timeout_ms, previous_timeout)
      else
        Application.delete_env(:taxi_be, :driver_response_timeout_ms)
      end
    end)
  end

  test "contacts the next driver when the current driver times out" do
    request = request()

    state = %{
      request: request,
      available_taxis: [
        %{nickname: "frodo"},
        %{nickname: "samwise"}
      ],
      contacted_taxi: nil,
      response_timer_ref: nil
    }

    assert {:noreply, state} =
             TaxiAllocationJob.handle_info(:contact_next_taxi, state)

    assert state.contacted_taxi.nickname == "frodo"
    assert state.available_taxis == [%{nickname: "samwise"}]
    assert is_reference(state.response_timer_ref)

    assert_receive {:driver_timeout, "frodo"}, 100

    assert {:noreply, state} =
             TaxiAllocationJob.handle_info({:driver_timeout, "frodo"}, state)

    assert state.contacted_taxi == nil
    assert state.response_timer_ref == nil
    assert_receive :contact_next_taxi
  end

  test "reject cancels the active response timer" do
    timer_ref = Process.send_after(self(), :unexpected_timeout, 1_000)

    state = %{
      request: request(),
      available_taxis: [%{nickname: "samwise"}],
      contacted_taxi: %{nickname: "frodo"},
      response_timer_ref: timer_ref
    }

    assert {:noreply, state} =
             TaxiAllocationJob.handle_info({:step2, "reject", "frodo"}, state)

    assert state.contacted_taxi == nil
    assert state.response_timer_ref == nil
    assert Process.read_timer(timer_ref) == false
    assert_receive :contact_next_taxi
    refute_receive :unexpected_timeout
  end

  test "ignores a late response from a previous driver" do
    state = %{
      request: request(),
      available_taxis: [],
      contacted_taxi: %{nickname: "samwise"},
      response_timer_ref: nil
    }

    assert {:noreply, ^state} =
             TaxiAllocationJob.handle_info({:step2, "accept", "frodo"}, state)
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
