defmodule TaxiBeWeb.TaxiAllocationJob do
  use GenServer

  def start_link(request, name) do
    GenServer.start_link(__MODULE__, request, name: name)
  end

  def start(request, name) do
    GenServer.start(__MODULE__, request, name: name)
  end

  def init(request) do
    Process.send(self(), :step1, [:nosuspend])

    {:ok,
     %{
       request: request,
       phase: :searching,
       contacted_taxis: %{},
       rejected_drivers: MapSet.new(),
       response_timer_ref: nil,
       accepted_driver: nil,
       arrival_timer_ref: nil,
       arrival_deadline_ms: nil
     }}
  end

  def handle_info(:step1, %{request: request} = state) do
    ride_fare_task =
      Task.async(fn ->
        request
        |> compute_ride_fare()
        |> notify_customer_ride_fare()
      end)

    candidate_taxis_task = Task.async(fn -> select_candidate_taxis(request) end)

    selected_candidate_taxis = Task.await(candidate_taxis_task, 30_000)
    Task.await(ride_fare_task, 30_000)

    Process.send(self(), {:contact_taxis, selected_candidate_taxis}, [:nosuspend])

    {:noreply, state}
  end

  def handle_info(
        {:contact_taxis, [_ | _] = taxis},
        %{request: request} = state
      ) do
    %{
      "pickup_address" => pickup_address,
      "dropoff_address" => dropoff_address,
      "booking_id" => booking_id
    } = request

    Enum.each(taxis, fn taxi ->
      TaxiBeWeb.Endpoint.broadcast(
        "driver:" <> taxi.nickname,
        "booking_request",
        %{
          msg: "Viaje de '#{pickup_address}' a '#{dropoff_address}'",
          bookingId: booking_id
        }
      )
    end)

    timer_ref =
      Process.send_after(
        self(),
        {:driver_group_timeout, booking_id},
        driver_response_timeout_ms()
      )

    {:noreply,
     %{
       state
       | contacted_taxis: Map.new(taxis, &{&1.nickname, &1}),
         response_timer_ref: timer_ref
     }}
  end

  def handle_info({:contact_taxis, []}, state) do
    notify_customer_unavailable(state.request)
    {:stop, :normal, state}
  end

  def handle_info(
        {:step2, "accept", driver},
        %{
          phase: :searching,
          request: request,
          contacted_taxis: contacted_taxis,
          response_timer_ref: timer_ref
        } = state
      )
      when is_map_key(contacted_taxis, driver) do
    cancel_timer(timer_ref)
    customer = request["username"]

    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer,
      "booking_request",
      %{
        msg: "#{driver} aceptó el viaje. Llegará aproximadamente en 5 minutos"
      }
    )

    close_driver_requests(state, "#{driver} aceptó el viaje")

    arrival_ms = taxi_arrival_ms()
    booking_id = request["booking_id"]
    arrival_timer_ref = Process.send_after(self(), {:taxi_arrived, booking_id}, arrival_ms)

    {:noreply,
     %{
       state
       | phase: :allocated,
         response_timer_ref: nil,
         accepted_driver: Map.fetch!(contacted_taxis, driver),
         arrival_timer_ref: arrival_timer_ref,
         arrival_deadline_ms: monotonic_ms() + arrival_ms
     }}
  end

  def handle_info(
        {:step2, "reject", driver},
        %{
          phase: :searching,
          contacted_taxis: contacted_taxis,
          rejected_drivers: rejected_drivers,
          response_timer_ref: timer_ref
        } = state
      )
      when is_map_key(contacted_taxis, driver) do
    IO.inspect("#{driver} rechazó el viaje")
    rejected_drivers = MapSet.put(rejected_drivers, driver)

    if MapSet.size(rejected_drivers) == map_size(contacted_taxis) do
      cancel_timer(timer_ref)
      notify_customer_unavailable(state.request)
      close_driver_requests(state, "Ningún conductor aceptó el viaje")
      {:stop, :normal, %{state | rejected_drivers: rejected_drivers}}
    else
      {:noreply, %{state | rejected_drivers: rejected_drivers}}
    end
  end

  def handle_info(
        {:driver_group_timeout, booking_id},
        %{
          phase: :searching,
          request: %{"booking_id" => booking_id}
        } = state
      ) do
    notify_customer_unavailable(state.request)
    close_driver_requests(state, "La solicitud expiró")
    {:stop, :normal, %{state | response_timer_ref: nil}}
  end

  def handle_info({:driver_group_timeout, _booking_id}, state) do
    {:noreply, state}
  end

  def handle_info({:step2, action, driver}, state)
      when action in ["accept", "reject"] do
    IO.inspect("Respuesta tardía de #{driver} ignorada")
    {:noreply, state}
  end

  def handle_info(
        {:cancel, customer},
        %{
          phase: :searching,
          request: %{"username" => customer},
          response_timer_ref: timer_ref
        } = state
      ) do
    cancel_timer(timer_ref)
    close_driver_requests(state, "El cliente canceló el viaje")
    notify_customer_cancellation(state.request, 0)
    {:stop, :normal, state}
  end

  def handle_info(
        {:cancel, customer},
        %{
          phase: :allocated,
          request: %{"username" => customer},
          accepted_driver: accepted_driver,
          arrival_timer_ref: arrival_timer_ref,
          arrival_deadline_ms: arrival_deadline_ms
        } = state
      ) do
    cancel_timer(arrival_timer_ref)

    remaining_ms = max(arrival_deadline_ms - monotonic_ms(), 0)

    fee =
      if remaining_ms <= cancellation_penalty_window_ms() do
        cancellation_fee()
      else
        0
      end

    notify_driver_cancellation(accepted_driver, state.request, fee)
    notify_customer_cancellation(state.request, fee)
    {:stop, :normal, state}
  end

  def handle_info({:cancel, _customer}, state) do
    {:noreply, state}
  end

  def handle_info(
        {:taxi_arrived, booking_id},
        %{
          phase: :allocated,
          request: %{"booking_id" => booking_id, "username" => customer},
          accepted_driver: accepted_driver
        } = state
      ) do
    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer,
      "booking_closed",
      %{
        bookingId: booking_id,
        msg: "#{accepted_driver.nickname} llegó. El viaje puede comenzar."
      }
    )

    {:stop, :normal, state}
  end

  def handle_info({:taxi_arrived, _booking_id}, state) do
    {:noreply, state}
  end

  def compute_ride_fare(request) do
    %{
      "pickup_address" => pickup_address,
      "dropoff_address" => dropoff_address
    } = request

    coord1 = TaxiBeWeb.Geolocator.geocode(pickup_address)
    coord2 = TaxiBeWeb.Geolocator.geocode(dropoff_address)
    {distance, _duration} = TaxiBeWeb.Geolocator.distance_and_duration(coord1, coord2)
    {request, Float.ceil(distance / 300)}
  end

  def notify_customer_ride_fare({request, fare}) do
    %{"username" => customer} = request

    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer,
      "booking_request",
      %{msg: "Ride fare: #{fare}"}
    )
  end

  def select_candidate_taxis(%{"pickup_address" => _pickup_address}) do
    [
      %{nickname: "frodo", latitude: 19.0319783, longitude: -98.2349368},
      %{nickname: "samwise", latitude: 19.0061167, longitude: -98.2697737},
      %{nickname: "pippin", latitude: 19.0092933, longitude: -98.2473716}
    ]
  end

  defp notify_customer_unavailable(request) do
    %{
      "pickup_address" => pickup_address,
      "dropoff_address" => dropoff_address,
      "username" => username
    } = request

    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> username,
      "booking_request",
      %{
        msg:
          "Viaje de '#{pickup_address}' a '#{dropoff_address}' cancelado: " <>
            "ningún conductor aceptó la solicitud"
      }
    )
  end

  defp close_driver_requests(state, message) do
    booking_id = state.request["booking_id"]

    Enum.each(state.contacted_taxis, fn {nickname, _taxi} ->
      TaxiBeWeb.Endpoint.broadcast(
        "driver:" <> nickname,
        "booking_closed",
        %{bookingId: booking_id, msg: message}
      )
    end)
  end

  defp notify_customer_cancellation(request, fee) do
    message =
      if fee > 0 do
        "Viaje cancelado. Se aplicó un cargo de $#{fee}."
      else
        "Viaje cancelado sin cargo."
      end

    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> request["username"],
      "booking_closed",
      %{bookingId: request["booking_id"], msg: message}
    )
  end

  defp notify_driver_cancellation(driver, request, fee) do
    TaxiBeWeb.Endpoint.broadcast(
      "driver:" <> driver.nickname,
      "booking_cancelled",
      %{
        bookingId: request["booking_id"],
        msg: "El cliente canceló el viaje. Cargo aplicado: $#{fee}."
      }
    )
  end

  defp driver_response_timeout_ms do
    Application.get_env(:taxi_be, :driver_response_timeout_ms, 60_000)
  end

  defp taxi_arrival_ms do
    Application.get_env(:taxi_be, :taxi_arrival_ms, 300_000)
  end

  defp cancellation_penalty_window_ms do
    Application.get_env(:taxi_be, :cancellation_penalty_window_ms, 180_000)
  end

  defp cancellation_fee do
    Application.get_env(:taxi_be, :cancellation_fee, 20)
  end

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end
end
