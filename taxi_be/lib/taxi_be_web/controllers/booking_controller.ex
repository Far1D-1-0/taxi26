defmodule TaxiBeWeb.BookingController do
  use TaxiBeWeb, :controller
  alias TaxiBeWeb.TaxiAllocationJob

  def create(conn, req) do
    IO.inspect(req)
    booking_id = UUID.uuid1()

    {:ok, _pid} =
      TaxiAllocationJob.start(
        Map.put(req, "booking_id", booking_id),
        String.to_atom(booking_id)
      )

    conn
    |> put_resp_header("Location", "/api/bookings/" <> booking_id)
    |> put_status(:created)
    |> json(%{
      msg: "We are processing your request",
      bookingId: booking_id
    })
  end

  def update(conn, %{"action" => "accept", "username" => username, "id" => id}) do
    IO.inspect("'#{username}' is accepting a booking request")

    dispatch_booking_message(
      conn,
      id,
      {:step2, "accept", username},
      "We will process your acceptance"
    )
  end

  def update(conn, %{"action" => "reject", "username" => username, "id" => id}) do
    IO.inspect("'#{username}' is rejecting a booking request")

    dispatch_booking_message(
      conn,
      id,
      {:step2, "reject", username},
      "We will process your rejection"
    )
  end

  def update(conn, %{"action" => "cancel", "username" => username, "id" => id}) do
    IO.inspect("'#{username}' is cancelling a booking request")

    dispatch_booking_message(
      conn,
      id,
      {:cancel, username},
      "We will process your cancellation"
    )
  end

  defp dispatch_booking_message(conn, id, message, response_message) do
    with {:ok, process_name} <- existing_process_name(id),
         pid when is_pid(pid) <- Process.whereis(process_name) do
      send(pid, message)
      json(conn, %{msg: response_message})
    else
      _ ->
        conn
        |> put_status(:gone)
        |> json(%{msg: "This booking is no longer active"})
    end
  end

  defp existing_process_name(id) do
    {:ok, String.to_existing_atom(id)}
  rescue
    ArgumentError -> :error
  end
end
