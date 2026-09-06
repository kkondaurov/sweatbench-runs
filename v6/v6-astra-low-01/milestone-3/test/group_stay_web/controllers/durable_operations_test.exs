defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Operation, Repo}
  import Ecto.Query

  defp opening do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "group_id" => "group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "occurred_on" => "2026-10-01",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 1000},
        %{"room_id" => "b", "nightly_rate_cents" => 1000}
      ]
    }
  end

  defp op(id, type, extra) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => type,
        "group_id" => "group",
        "occurred_on" => "2026-10-02"
      },
      extra
    )
  end

  defp batch(ops) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => ops})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp lookup(id) do
    build_conn() |> get("/api/v1/operations/#{id}") |> json_response(200) |> Map.fetch!("data")
  end

  test "exact retries replay original revisions and dates through later changes" do
    move =
      op("move", "reschedule_group", %{"new_arrival_on" => "2027-01-01", "expected_revision" => 1})

    pay = op("pay", "record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 2})
    cancel = op("cancel", "cancel_group", %{"refund_method" => "hotel_credit"})
    operations = [opening(), move, pay, cancel]
    results = batch(operations)
    assert batch(operations) == results
    assert batch(operations ++ operations) == results ++ results
    assert Enum.map(operations, &lookup(&1["operation_id"])) == results
    assert GroupStay.Reservations.get("group").revision == 4
    assert GroupStay.Reservations.credit("guest", ~D[2026-10-02]).available_cents == 110
    assert Repo.aggregate(GroupStay.CreditLot, :count) == 1
    assert Repo.aggregate(Operation, :count) == 4
  end

  test "rejections remain original after domain state changes and conflicts never replace them" do
    missing = op("missing", "record_cash_payment", %{"amount_cents" => 100})

    [rejected, _, paid] =
      batch([missing, opening(), op("pay", "record_cash_payment", %{"amount_cents" => 10})])

    assert rejected["code"] == "group_not_found"
    assert paid["revision"] == 2
    stale = op("stale", "record_cash_payment", %{"amount_cents" => -1, "expected_revision" => 1})
    [original] = batch([stale])
    assert original["code"] == "stale_revision"
    batch([op("later", "record_cash_payment", %{"amount_cents" => 1})])
    assert batch([missing, stale]) == [rejected, original]
    assert original["actual_revision"] == 2

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(stale, "expected_revision", 3)])

    assert lookup("stale") == original
    assert GroupStay.Reservations.get("group").revision == 3
  end

  test "audit retains complete JSON and commit order while object ordering is irrelevant" do
    first = Map.put(opening(), "metadata", %{"nested" => [%{"b" => 2, "a" => 1}, nil, true]})
    second = op("bad", "unknown", %{"extra" => [1, 2]})
    originals = batch([first, second])
    reordered = first |> Jason.encode!() |> Jason.decode!()
    assert batch([reordered, second]) == originals

    # Send deliberately reversed object keys on the wire, including room keys.
    encoded_rooms =
      Enum.map_join(first["rooms"], ",", fn room ->
        ~s({"nightly_rate_cents":#{room["nightly_rate_cents"]},"room_id":#{Jason.encode!(room["room_id"])}})
      end)

    encoded =
      first
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.map_join(",", fn {key, value} ->
        Jason.encode!(key) <>
          ":" <>
          if(key == "rooms", do: "[" <> encoded_rooms <> "]", else: Jason.encode!(value))
      end)

    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/partner-batches", ~s({"operations":[{#{encoded}}]}))
           |> json_response(200) == %{"results" => [hd(originals)]}

    for changed <- [
          Map.put(first, "rooms", Enum.reverse(first["rooms"])),
          Map.put(first, "metadata", %{"nested" => [nil, true]}),
          Map.delete(first, "metadata"),
          Map.put(first, "expected_revision", nil),
          Map.put(second, "extra", [1.0, 2])
        ] do
      assert [%{"code" => "operation_id_conflict"}] = batch([changed])
    end

    records = Repo.all(from o in Operation, order_by: o.id)
    assert Enum.map(records, & &1.submission) === [first, second]
    assert Enum.map(records, & &1.type) == ["open_group", "unknown"]
    assert Enum.map(records, & &1.result) == originals
    assert lookup("open") == hd(originals)

    assert build_conn() |> get("/api/v1/operations/absent") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end

  test "identifiable malformed operations are remembered and unidentifiable values do not block a batch" do
    malformed = %{"operation_id" => "malformed", "type" => ["bad"], "anything" => %{"x" => 1}}
    [first] = batch([malformed])
    assert first["code"] == "invalid_operation"
    assert batch([malformed]) == [first]
    assert lookup("malformed") == first
    assert Repo.get_by!(Operation, operation_id: "malformed").submission == malformed

    assert Enum.map(batch([nil, [], %{}, %{"operation_id" => ""}, opening()]), & &1["status"]) ==
             ["rejected", "rejected", "rejected", "rejected", "applied"]
  end

  test "credit redemption retries do not consume or restore lots twice" do
    batch([
      opening(),
      op("cash", "record_cash_payment", %{"amount_cents" => 100}),
      op("issue", "cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    batch([Map.merge(opening(), %{"operation_id" => "open-next", "group_id" => "next"})])
    redeem = op("redeem", "apply_hotel_credit", %{"group_id" => "next", "amount_cents" => 100})
    [result, retry] = batch([redeem, redeem])
    assert result == retry
    assert GroupStay.Reservations.credit("guest", ~D[2026-10-02]).available_cents == 10
    cancel = op("restore", "cancel_group", %{"group_id" => "next"})
    [result, retry] = batch([cancel, cancel])
    assert result == retry
    assert GroupStay.Reservations.credit("guest", ~D[2026-10-02]).available_cents == 110
  end

  test "unexpected storage faults return HTTP 500 and do not remember or continue the operation" do
    Repo.query!("""
    CREATE TRIGGER fail_http_audit BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    fault = op("fault", "record_cash_payment", %{"amount_cents" => 100})
    later = op("later", "record_cash_payment", %{"amount_cents" => 10})

    assert_error_sent 500, fn -> batch([opening(), fault, later]) end

    assert GroupStay.Reservations.get("group").revision == 1
    assert GroupStay.Reservations.operation("fault") == nil
    assert GroupStay.Reservations.operation("later") == nil
    Repo.query!("DROP TRIGGER fail_http_audit")
    assert Enum.map(batch([opening(), fault, later]), & &1["revision"]) == [1, 2, 3]
  end
end
