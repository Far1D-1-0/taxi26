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
       available_taxis: [],
       contacted_taxi: nil,
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

    Process.send(self(), :contact_next_taxi, [:nosuspend])

    {:noreply, %{state | available_taxis: selected_candidate_taxis}}
  end

  def handle_info(
        :contact_next_taxi,
        %{request: request, available_taxis: [taxi | remaining_taxis]} = state
      ) do
    %{
      "pickup_address" => pickup_address,
      "dropoff_address" => dropoff_address,
      "booking_id" => booking_id
    } = request

    TaxiBeWeb.Endpoint.broadcast(
      "driver:" <> taxi.nickname,
      "booking_request",
      %{
        msg: "Viaje de '#{pickup_address}' a '#{dropoff_address}'",
        bookingId: booking_id
      }
    )

    timer_ref =
      Process.send_after(
        self(),
        {:driver_timeout, taxi.nickname},
        driver_response_timeout_ms()
      )

    {:noreply,
     %{
       state
       | contacted_taxi: taxi,
         available_taxis: remaining_taxis,
         response_timer_ref: timer_ref
     }}
  end

  def handle_info(
        :contact_next_taxi,
        %{request: request, available_taxis: []} = state
      ) do
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
            "no hay conductores disponibles"
      }
    )

    {:stop, :normal, state}
  end

  def handle_info(
        {:step2, "accept", driver},
        %{
          request: request,
          contacted_taxi: %{nickname: driver},
          response_timer_ref: timer_ref
        } = state
      ) do
    cancel_timer(timer_ref)
    customer = request["username"]

    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer,
      "booking_request",
      %{
        msg: "#{driver} aceptó el viaje. Llegará aproximadamente en 5 minutos"
      }
    )

    {:stop, :normal, state}
  end

  def handle_info(
        {:step2, "reject", driver},
        %{
          contacted_taxi: %{nickname: driver},
          response_timer_ref: timer_ref
        } = state
      ) do
    cancel_timer(timer_ref)
    IO.inspect("#{driver} rechazó el viaje")

    Process.send(self(), :contact_next_taxi, [:nosuspend])

    {:noreply,
     %{
       state
       | contacted_taxi: nil,
         response_timer_ref: nil
     }}
  end

  def handle_info(
        {:driver_timeout, driver},
        %{contacted_taxi: %{nickname: driver}} = state
      ) do
    IO.inspect("#{driver} no respondió a tiempo")
    Process.send(self(), :contact_next_taxi, [:nosuspend])

    {:noreply,
     %{
       state
       | contacted_taxi: nil,
         response_timer_ref: nil
     }}
  end

  def handle_info({:driver_timeout, _driver}, state) do
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

  defp driver_response_timeout_ms do
    Application.get_env(:taxi_be, :driver_response_timeout_ms, 60_000)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end
end
