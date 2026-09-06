defmodule GroupStayWeb.PartnerController do
  use GroupStayWeb, :controller
  alias GroupStay.Reservations

  def create_batch(conn, %{"operations" => operations}) when is_list(operations) do
    json(conn, %{results: Reservations.apply_batch(operations)})
  end

  def create_batch(conn, _params) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_batch"}})
  end

  def show_group(conn, %{"group_id" => group_id}) do
    case Reservations.get_group(group_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "group_not_found"}})
      group -> json(conn, %{data: group})
    end
  end

  def show_operation(conn, %{"operation_id" => operation_id}) do
    case Reservations.get_operation(operation_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "operation_not_found"}})
      result -> json(conn, %{data: result})
    end
  end

  def show_payment(conn, %{"payment_operation_id" => id}) do
    case Reservations.get_payment(id) do
      {:ok, statement} ->
        json(conn, %{data: statement})

      {:error, code} ->
        status = if code == "operation_not_found", do: :not_found, else: :unprocessable_entity
        conn |> put_status(status) |> json(%{error: %{code: code}})
    end
  end

  def ledger(conn, params) do
    with_read_date(conn, params, &Reservations.ledger/1)
  end

  def daily_report(conn, params) do
    case GroupStay.FinanceReporting.daily_report(params["date"]) do
      {:ok, report} ->
        json(conn, %{data: ordered_json(report)})

      {:error, code} ->
        status = if code == "invalid_reporting_date", do: :unprocessable_entity, else: :not_found
        conn |> put_status(status) |> json(%{error: %{code: code}})
    end
  end

  # Atom map iteration order can differ between BEAM instances. Published report
  # bytes must survive restarts, so order every JSON object by its string keys.
  defp ordered_json(%Date{} = date), do: date

  defp ordered_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), ordered_json(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp ordered_json(value) when is_list(value), do: Enum.map(value, &ordered_json/1)
  defp ordered_json(value), do: value

  def guest_credit(conn, %{"guest_id" => guest_id} = params) do
    with_read_date(conn, params, &Reservations.guest_credit(guest_id, &1))
  end

  defp with_read_date(conn, params, read) do
    on = Map.get(params, "on", Date.to_iso8601(Date.utc_today()))

    case if(is_binary(on), do: Date.from_iso8601(on), else: {:error, :invalid_date}) do
      {:ok, date} -> json(conn, %{data: read.(date)})
      _ -> conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
