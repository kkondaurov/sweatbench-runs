defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Repo, Reservations}

  defp open(id \\ "g", rates \\ [1000, 1000, 1000], extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{id}",
        "type" => "open_group",
        "group_id" => id,
        "guest_id" => "guest",
        "property_id" => "hotel",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02",
        "rate_plan" => "flexible",
        "rooms" =>
          Enum.with_index(rates, fn rate, i ->
            %{"room_id" => "r#{i}", "nightly_rate_cents" => rate}
          end)
      },
      extra
    )
  end

  defp op(id, type, extra) do
    Map.merge(
      %{"operation_id" => id, "type" => type, "group_id" => "g", "occurred_on" => "2027-02-01"},
      extra
    )
  end

  defp pay(id, amount, group \\ "g"),
    do: op(id, "record_cash_payment", %{"group_id" => group, "amount_cents" => amount})

  defp cancel(id, rooms, extra),
    do: op(id, "cancel_rooms", Map.put(extra, "room_ids", rooms))

  defp reduce(id, payment, amount, extra),
    do:
      op(
        id,
        "reduce_cash_payment",
        Map.merge(%{"payment_operation_id" => payment, "amount_cents" => amount}, extra)
      )
      |> Map.delete("group_id")

  defp charge(id, payment, extra \\ %{}),
    do:
      op(id, "charge_back_payment", Map.put(extra, "payment_operation_id", payment))
      |> Map.delete("group_id")

  defp batch(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{"operations" => ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp apply!(op) do
    [result] = batch([op])
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp group(id \\ "g"),
    do: build_conn() |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp ledger(on \\ "2027-02-01"),
    do:
      build_conn()
      |> get("/api/v1/ledger", %{"on" => on})
      |> json_response(200)
      |> Map.fetch!("data")

  defp credit(on \\ "2027-02-01"),
    do: Reservations.guest_credit("guest", Date.from_iso8601!(on)).available_cents

  defp transfer(id, source, destination, amount, extra \\ %{}) do
    op(
      id,
      "transfer_deposit",
      Map.merge(
        %{
          "source_group_id" => source,
          "destination_group_id" => destination,
          "amount_cents" => amount
        },
        extra
      )
    )
    |> Map.delete("group_id")
  end

  defp statement(id) do
    build_conn() |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")
  end

  test "mixed funding moves newest first, fills in draw order, and retries exactly" do
    for id <- ~w(seed g d), do: apply!(open(id))
    apply!(pay("seed-pay", 100, "seed"))

    apply!(
      op("issue", "cancel_group", %{"group_id" => "seed", "refund_method" => "hotel_credit"})
    )

    original = apply!(pay("first", 250))
    apply!(op("credit", "apply_hotel_credit", %{"amount_cents" => 110}))
    apply!(pay("last", 100))
    before = ledger()

    request =
      transfer("move", "g", "d", 260, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 1
      })

    result = apply!(request)

    assert result == %{
             "operation_id" => "move",
             "status" => "applied",
             "source_group_id" => "g",
             "destination_group_id" => "d",
             "amount_cents" => 260,
             "source_outstanding_deposit_cents" => 400,
             "destination_outstanding_deposit_cents" => 340,
             "source_revision" => 5,
             "destination_revision" => 2
           }

    assert ledger() == before

    assert Enum.map(group("d")["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {100, 100},
             {50, 10},
             {0, 0}
           ]

    assert statement("first")["held_by_group"] == [
             %{"group_id" => "d", "amount_cents" => 50},
             %{"group_id" => "g", "amount_cents" => 200}
           ]

    assert apply!(request) == result
    assert apply!(pay("first", 250)) == original
    apply!(cancel("cancel-d", ["r1", "r0"], %{"group_id" => "d"}))
    assert credit() == 110
    assert statement("last")["held_by_group"] == []
    assert statement("seed-pay") |> Map.has_key?("held_by_group") == false
  end

  test "reductions follow global reverse allocation order and bump each changed group once" do
    for id <- ~w(g a z), do: apply!(open(id))
    apply!(pay("p", 500))
    apply!(transfer("t1", "g", "a", 150))
    apply!(transfer("t2", "g", "z", 100))
    result = apply!(reduce("reduce", "p", 180, %{"expected_revision" => 4}))
    assert result["revision"] == 5
    assert group("a")["revision"] == 3
    assert group("z")["revision"] == 3

    assert statement("p")["held_by_group"] == [
             %{"group_id" => "a", "amount_cents" => 70},
             %{"group_id" => "g", "amount_cents" => 250}
           ]

    assert ledger()["cash_reduced_cents"] == 180
    apply!(charge("cb", "p", %{"expected_revision" => 5}))
    assert group("g")["revision"] == 6
    assert group("a")["revision"] == 4
    assert group("z")["revision"] == 3
    assert statement("p")["charged_back_cents"] == 320
    assert statement("p")["held_by_group"] == []
    assert ledger()["cash_held_cents"] == 0
  end

  test "destination settlement, conversion clawback and paused credit expiry survive transfers" do
    for id <- ~w(g d reuse), do: apply!(open(id))
    apply!(open("nonref", [1000], %{"rate_plan" => "advance_purchase"}))
    apply!(pay("p", 500))
    apply!(transfer("to-d", "g", "d", 200))
    apply!(transfer("to-n", "g", "nonref", 100))
    apply!(op("convert", "cancel_group", %{"group_id" => "d", "refund_method" => "hotel_credit"}))
    apply!(op("retain", "cancel_group", %{"group_id" => "nonref"}))
    apply!(op("redeem", "apply_hotel_credit", %{"group_id" => "reuse", "amount_cents" => 220}))
    apply!(transfer("credit-move", "reuse", "g", 220, %{"occurred_on" => "2028-03-01"}))
    before = group()["revision"]
    apply!(charge("cb", "p"))
    assert group()["revision"] == before + 1
    assert group("d")["revision"] == 4
    assert group("nonref")["revision"] == 4
    assert group("reuse")["revision"] == 3
    assert ledger("2028-03-01")["credit_shortfall_cents"] == 220
    assert ledger()["cash_converted_to_credit_cents"] == 0
    assert ledger()["cash_retained_cents"] == 0

    apply!(
      op("reschedule", "reschedule_group", %{
        "occurred_on" => "2028-03-01",
        "new_arrival_on" => "2028-06-01"
      })
    )

    apply!(op("restore", "cancel_group", %{"occurred_on" => "2028-03-01"}))
    assert ledger("2028-03-01")["credit_shortfall_cents"] == 0
    assert ledger("2028-03-01")["credit_liability_cents"] == 0
  end

  test "chained transfers create new allocation positions and preserve statement history after full reduction" do
    for id <- ~w(g d e), do: apply!(open(id))
    apply!(pay("p", 400))
    apply!(cancel("closed-room", ["r0"], %{"group_id" => "d"}))
    apply!(transfer("first-hop", "g", "d", 250))
    assert Enum.map(group("d")["rooms"], & &1["cash_paid_cents"]) == [0, 200, 50]
    apply!(transfer("second-hop", "d", "e", 100))
    apply!(transfer("return", "e", "g", 100))
    apply!(reduce("partial", "p", 75, %{}))

    assert statement("p")["held_by_group"] == [
             %{"group_id" => "d", "amount_cents" => 150},
             %{"group_id" => "g", "amount_cents" => 175}
           ]

    apply!(reduce("rest", "p", 325, %{}))
    assert statement("p")["held_by_group"] == []
    assert statement("p")["reduced_cents"] == 400
    assert ledger()["cash_reduced_cents"] == 400
    assert group("e")["revision"] == 3
  end

  test "validation precedence, rejection atomicity and durable rejected results" do
    apply!(open())
    apply!(open("d"))
    apply!(open("other", [1000], %{"guest_id" => "someone-else"}))
    apply!(open("inactive"))
    apply!(op("cancel", "cancel_group", %{"group_id" => "inactive"}))
    apply!(pay("p", 100))

    cases = [
      {transfer("missing-s", "missing", "absent", 0), "group_not_found", "missing"},
      {transfer("missing-d", "g", "absent", 0, %{"expected_revision" => 0}), "group_not_found",
       "absent"},
      {transfer("stale-s", "g", "d", 0, %{
         "expected_revision" => 0,
         "destination_expected_revision" => 0
       }), "stale_revision", "g"},
      {transfer("stale-d", "g", "d", 0, %{"destination_expected_revision" => 0}),
       "stale_revision", "d"},
      {transfer("same", "g", "g", 1), "invalid_transfer", nil},
      {transfer("guest", "g", "other", 1), "invalid_transfer", nil},
      {transfer("inactive-s", "inactive", "d", 1), "group_not_active", "inactive"},
      {transfer("inactive-d", "g", "inactive", 1), "group_not_active", "inactive"},
      {transfer("amount", "g", "d", 0), "invalid_amount", nil},
      {transfer("held", "g", "d", 101), "transfer_exceeds_held_funding", nil}
    ]

    before = {group(), group("d"), ledger(), Repo.all(GroupStay.Reservations.Funding)}

    for {request, code, id} <- cases do
      [result] = batch([request])
      assert result["code"] == code
      assert result["group_id"] == id
      assert batch([request]) == [result]
    end

    assert before == {group(), group("d"), ledger(), Repo.all(GroupStay.Reservations.Funding)}
    apply!(pay("fill", 600, "d"))
    [result, applied] = batch([transfer("full", "g", "d", 1), transfer("ok", "d", "g", 100)])
    assert result["code"] == "transfer_exceeds_outstanding"
    assert applied["status"] == "applied"
    [conflict] = batch([transfer("ok", "d", "g", 99)])
    assert conflict["code"] == "operation_id_conflict"
  end
end
