defmodule GroupStay.Operations do
  alias GroupStay.Groups
  alias GroupStay.Finance
  alias GroupStay.Operations.PartnerOperation
  alias GroupStay.Repo

  def process(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if usable_identifier?(operation_id) do
      submission = json_value(operation)

      Repo.transaction(
        fn -> process_durable(operation_id, submission) end,
        mode: :immediate
      )
      |> case do
        {:ok, result} -> result
        {:error, reason} -> raise "operation transaction failed: #{inspect(reason)}"
      end
    else
      rejected(operation_id, :invalid_operation)
    end
  end

  def process(_operation), do: rejected(nil, :invalid_operation)

  def get(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      operation -> {:ok, operation.result}
    end
  end

  defp process_durable(operation_id, submission) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      %PartnerOperation{submission: ^submission, result: result} ->
        result

      %PartnerOperation{} ->
        rejected(operation_id, :operation_id_conflict) |> json_value()

      nil ->
        result = dispatch(Map.get(submission, "type"), operation_id, submission) |> json_value()

        %{
          operation_id: operation_id,
          operation_type: submitted_type(submission),
          submission: submission,
          result: result
        }
        |> PartnerOperation.changeset()
        |> Repo.insert!()

        result
    end
  end

  defp dispatch("open_group", operation_id, operation) do
    with {:ok, occurred_on} <- date(operation, "occurred_on"),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, guest_id} <- identifier(operation, "guest_id"),
         {:ok, property_id} <- identifier(operation, "property_id"),
         {:ok, arrival_on} <- supplied_date(operation, "arrival_on"),
         {:ok, departure_on} <- supplied_date(operation, "departure_on"),
         {:ok, rate_plan} <- supplied(operation, "rate_plan"),
         {:ok, rooms} <- supplied(operation, "rooms"),
         {:ok, rooms} <- normalize_rooms(rooms) do
      Groups.open_group(%{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: occurred_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        rooms: rooms
      })
      |> result(operation_id, group_id)
    else
      {:error, :invalid_stay} -> rejected(operation_id, :invalid_stay)
      _error -> rejected(operation_id, :invalid_operation)
    end
  end

  defp dispatch("record_cash_payment", operation_id, operation) do
    with {:ok, occurred_on} <- date(operation, "occurred_on"),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, amount_cents} <- supplied(operation, "amount_cents"),
         {:ok, expected_revision} <- expected_revision(operation) do
      Groups.record_cash_payment(
        group_id,
        amount_cents,
        occurred_on,
        expected_revision,
        operation_id
      )
      |> result(operation_id, group_id)
    else
      _error -> rejected(operation_id, :invalid_operation)
    end
  end

  defp dispatch("reschedule_group", operation_id, operation) do
    with {:ok, occurred_on} <- date(operation, "occurred_on"),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, new_arrival_value} <- supplied(operation, "new_arrival_on"),
         {:ok, expected_revision} <- expected_revision(operation) do
      Groups.reschedule_group(group_id, occurred_on, new_arrival_value, expected_revision)
      |> result(operation_id, group_id)
    else
      _error -> rejected(operation_id, :invalid_operation)
    end
  end

  defp dispatch("cancel_group", operation_id, operation) do
    with {:ok, occurred_on} <- date(operation, "occurred_on"),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, expected_revision} <- expected_revision(operation) do
      refund_method = Map.get(operation, "refund_method", "cash")

      Groups.cancel_group(
        group_id,
        occurred_on,
        expected_revision,
        refund_method,
        operation_id
      )
      |> result(operation_id, group_id)
    else
      _error -> rejected(operation_id, :invalid_operation)
    end
  end

  defp dispatch("cancel_rooms", operation_id, operation) do
    with {:ok, occurred_on} <- date(operation, "occurred_on"),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, room_ids} <- supplied(operation, "room_ids"),
         {:ok, expected_revision} <- expected_revision(operation) do
      refund_method = Map.get(operation, "refund_method", "cash")

      Groups.cancel_rooms(
        group_id,
        room_ids,
        occurred_on,
        expected_revision,
        refund_method,
        operation_id
      )
      |> result(operation_id, group_id)
    else
      _error -> rejected(operation_id, :invalid_operation)
    end
  end

  defp dispatch("apply_hotel_credit", operation_id, operation) do
    with {:ok, occurred_on} <- date(operation, "occurred_on"),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, amount_cents} <- supplied(operation, "amount_cents"),
         {:ok, expected_revision} <- expected_revision(operation) do
      Groups.apply_hotel_credit(
        group_id,
        amount_cents,
        occurred_on,
        expected_revision,
        operation_id
      )
      |> result(operation_id, group_id)
    else
      _error -> rejected(operation_id, :invalid_operation)
    end
  end

  defp dispatch("transfer_deposit", operation_id, operation) do
    with {:ok, occurred_on} <- date(operation, "occurred_on"),
         {:ok, source_group_id} <- identifier(operation, "source_group_id"),
         {:ok, destination_group_id} <- identifier(operation, "destination_group_id"),
         {:ok, amount_cents} <- supplied(operation, "amount_cents"),
         {:ok, expected_revision} <- expected_revision(operation),
         {:ok, destination_expected_revision} <-
           optional_revision(operation, "destination_expected_revision") do
      Groups.transfer_deposit(
        source_group_id,
        destination_group_id,
        amount_cents,
        occurred_on,
        expected_revision,
        destination_expected_revision,
        operation_id
      )
      |> transfer_result(operation_id)
    else
      _error -> rejected(operation_id, :invalid_operation)
    end
  end

  defp dispatch("reduce_cash_payment", operation_id, operation) do
    with {:ok, occurred_on} <- date(operation, "occurred_on"),
         {:ok, payment_operation_id} <- identifier(operation, "payment_operation_id"),
         {:ok, amount_cents} <- supplied(operation, "amount_cents"),
         {:ok, expected_revision} <- expected_revision(operation) do
      Groups.reduce_cash_payment(
        payment_operation_id,
        amount_cents,
        occurred_on,
        expected_revision,
        operation_id
      )
      |> payment_result(operation_id, payment_operation_id)
    else
      _error -> rejected(operation_id, :invalid_operation)
    end
  end

  defp dispatch("charge_back_payment", operation_id, operation) do
    with {:ok, occurred_on} <- date(operation, "occurred_on"),
         {:ok, payment_operation_id} <- identifier(operation, "payment_operation_id"),
         {:ok, expected_revision} <- expected_revision(operation) do
      Groups.charge_back_payment(
        payment_operation_id,
        occurred_on,
        expected_revision,
        operation_id
      )
      |> payment_result(operation_id, payment_operation_id)
    else
      _error -> rejected(operation_id, :invalid_operation)
    end
  end

  defp dispatch("start_finance_reporting", operation_id, operation) do
    with {:ok, starts_on} <- reporting_date(operation, "starts_on") do
      Finance.start(starts_on)
      |> case do
        {:ok, fields} ->
          Map.merge(%{operation_id: operation_id, status: "applied"}, fields)

        {:error, code} ->
          rejected(operation_id, code)
      end
    else
      _error -> rejected(operation_id, :invalid_reporting_date)
    end
  end

  defp dispatch(_type, operation_id, _operation),
    do: rejected(operation_id, :invalid_operation)

  defp result({:ok, fields}, operation_id, _group_id),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, fields)

  defp result({:error, {:stale_revision, expected, actual}}, operation_id, group_id) do
    rejected(operation_id, :stale_revision, %{
      group_id: group_id,
      expected_revision: expected,
      actual_revision: actual
    })
  end

  defp result({:error, code}, operation_id, group_id),
    do: rejected(operation_id, code, %{group_id: group_id})

  defp payment_result({:ok, fields}, operation_id, _payment_operation_id),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, fields)

  defp payment_result(
         {:error, {:stale_payment_revision, group_id, expected, actual}},
         operation_id,
         _payment_operation_id
       ) do
    rejected(operation_id, :stale_revision, %{
      group_id: group_id,
      expected_revision: expected,
      actual_revision: actual
    })
  end

  defp payment_result({:error, code}, operation_id, payment_operation_id),
    do: rejected(operation_id, code, %{payment_operation_id: payment_operation_id})

  defp transfer_result({:ok, fields}, operation_id),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, fields)

  defp transfer_result(
         {:error, {:stale_transfer_revision, group_id, expected, actual}},
         operation_id
       ) do
    rejected(operation_id, :stale_revision, %{
      group_id: group_id,
      expected_revision: expected,
      actual_revision: actual
    })
  end

  defp transfer_result({:error, {:transfer_group_error, group_id, code}}, operation_id),
    do: rejected(operation_id, code, %{group_id: group_id})

  defp transfer_result({:error, code}, operation_id), do: rejected(operation_id, code)

  defp rejected(operation_id, code, extra \\ %{}) do
    Map.merge(
      %{operation_id: operation_id, status: "rejected", code: Atom.to_string(code)},
      extra
    )
  end

  defp date(operation, key) do
    with {:ok, value} <- supplied(operation, key),
         true <- is_binary(value),
         {:ok, parsed} <- Date.from_iso8601(value) do
      {:ok, parsed}
    else
      _error -> {:error, :invalid_operation}
    end
  end

  defp supplied_date(operation, key) do
    with {:ok, value} <- supplied(operation, key),
         true <- is_binary(value),
         {:ok, parsed} <- Date.from_iso8601(value) do
      {:ok, parsed}
    else
      _error -> {:error, :invalid_stay}
    end
  end

  defp reporting_date(operation, key) do
    with {:ok, value} <- supplied(operation, key),
         true <- is_binary(value),
         {:ok, parsed} <- Date.from_iso8601(value) do
      {:ok, parsed}
    else
      _error -> {:error, :invalid_reporting_date}
    end
  end

  defp identifier(operation, key) do
    with {:ok, value} <- supplied(operation, key),
         true <- usable_identifier?(value) do
      {:ok, value}
    else
      _error -> {:error, :invalid_operation}
    end
  end

  defp supplied(operation, key) do
    case Map.fetch(operation, key) do
      {:ok, nil} -> {:error, :invalid_operation}
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_operation}
    end
  end

  defp expected_revision(operation) do
    optional_revision(operation, "expected_revision")
  end

  defp optional_revision(operation, key) do
    case Map.fetch(operation, key) do
      :error -> {:ok, :any}
      {:ok, revision} when is_integer(revision) and revision > 0 -> {:ok, revision}
      _other -> {:error, :invalid_operation}
    end
  end

  defp normalize_rooms(rooms) when is_list(rooms) do
    Enum.reduce_while(rooms, {:ok, []}, fn room, {:ok, normalized} ->
      with true <- is_map(room),
           {:ok, room_id} <- identifier(room, "room_id"),
           {:ok, nightly_rate_cents} <- supplied(room, "nightly_rate_cents") do
        {:cont, {:ok, [%{room_id: room_id, nightly_rate_cents: nightly_rate_cents} | normalized]}}
      else
        _error -> {:halt, {:error, :invalid_operation}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_rooms(_rooms), do: {:ok, :invalid_rooms}

  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_submission), do: nil

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp usable_identifier?(value), do: is_binary(value) and String.trim(value) != ""
end
