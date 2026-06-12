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
       contacted_taxis: %{},
       rejected_drivers: MapSet.new(),
       response_timer_ref: nil
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
    {:stop, :normal, state}
  end

  def handle_info(
        {:step2, "reject", driver},
        %{
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
        %{request: %{"booking_id" => booking_id}} = state
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

  defp driver_response_timeout_ms do
    Application.get_env(:taxi_be, :driver_response_timeout_ms, 60_000)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end
end
