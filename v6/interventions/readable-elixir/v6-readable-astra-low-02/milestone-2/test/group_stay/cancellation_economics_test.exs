defmodule GroupStay.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, Group}

  defp open(id, attrs \\ %{}) do
    Map.merge(
      %{
        "type" => "open_group",
        "operation_id" => "open-" <> id,
        "group_id" => id,
        "guest_id" => "guest",
        "property_id" => "hotel",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 100_000}]
      },
      attrs
    )
  end

  defp op(type, id, attrs) do
    Map.merge(
      %{
        "type" => type,
        "operation_id" => type <> "-" <> id,
        "group_id" => id,
        "occurred_on" => "2027-01-01"
      },
      attrs
    )
  end

  defp submit(ops), do: Reservations.submit(ops)

  defp issue(id, amount, date \\ "2027-01-01") do
    [_, _, result] =
      submit([
        open(id),
        op("record_cash_payment", id, %{"amount_cents" => amount}),
        op("cancel_group", id, %{"occurred_on" => date, "refund_method" => "hotel_credit"})
      ])

    assert result.status == "applied"
    result
  end

  defp snapshot, do: {Repo.all(Group), Repo.all(CreditLot), Repo.all(CreditAllocation)}

  test "policy selection, inclusive deadlines and fixed policy after moving" do
    for {id, booking, plan, version, cutoff} <- [
          {"old", "2026-12-31", "flexible", "flex-14", ~D[2027-05-18]},
          {"new", "2027-01-01", "flexible", "flex-30", ~D[2027-05-02]},
          {"advance", "2026-12-31", "advance_purchase", "advance-nonrefundable", nil}
        ] do
      submit([open(id, %{"occurred_on" => booking, "rate_plan" => plan})])
      assert %{policy_version: ^version, refundable_until: ^cutoff} = Reservations.get_group(id)
      [moved] = submit([op("reschedule_group", id, %{"new_arrival_on" => "2028-06-01"})])
      assert moved.policy_version == version
      assert moved.new_departure_on == ~D[2028-06-02]
    end

    for {id, on, refund} <- [{"boundary", "2027-05-02", 100}, {"late", "2027-05-03", 0}] do
      [_, _, result] =
        submit([
          open(id),
          op("record_cash_payment", id, %{"amount_cents" => 100}),
          op("cancel_group", id, %{"occurred_on" => on})
        ])

      assert result.refunded_cents == refund
      assert result.retained_cents == 100 - refund
    end
  end

  test "cash conversion rounds half cents upward and read expiry is inclusive", %{conn: conn} do
    assert %{credit_issued_cents: 6, refunded_cents: 0, retained_cents: 0} = issue("source", 5)

    assert %{cash_held_cents: 0, cash_converted_to_credit_cents: 5, credit_liability_cents: 6} =
             Reservations.ledger(~D[2028-01-01])

    assert Reservations.ledger(~D[2028-01-02]).credit_liability_cents == 0
    data = conn |> get("/api/v1/guests/guest/credit?on=2028-01-01") |> json_response(200)
    assert data["data"]["available_cents"] == 6

    assert [%{"source_operation_id" => "cancel_group-source", "expires_on" => "2028-01-01"}] =
             data["data"]["lots"]

    assert Reservations.guest_credit("guest", ~D[2028-01-02]).lots == []
    assert Reservations.guest_credit("unknown").available_cents == 0

    assert build_conn() |> get("/api/v1/ledger?on=bad") |> json_response(422) ==
             %{"error" => %{"code" => "invalid_date"}}
  end

  test "lots are consumed by expiry then source identifier and restored without a bonus" do
    issue("z", 100, "2027-01-01")
    issue("a", 100, "2027-01-01")
    issue("early", 100, "2026-12-31")
    submit([open("target"), op("apply_hotel_credit", "target", %{"amount_cents" => 150})])

    assert Enum.map(
             Reservations.guest_credit("guest", ~D[2027-01-01]).lots,
             &{&1.source_operation_id, &1.remaining_cents}
           ) ==
             [{"cancel_group-a", 70}, {"cancel_group-z", 110}]

    assert %{cash_paid_cents: 0, credit_paid_cents: 150, deposit_paid_cents: 150} =
             Reservations.get_group("target")

    assert Reservations.ledger(~D[2027-01-01]).credit_liability_cents == 330
    [result] = submit([op("cancel_group", "target", %{"refund_method" => "hotel_credit"})])
    assert result.credit_issued_cents == 0
    assert Reservations.guest_credit("guest", ~D[2027-01-01]).available_cents == 330
  end

  test "applied credit pauses expiry and expired restoration removes liability" do
    issue("source", 100)

    submit([
      open("target", %{"arrival_on" => "2029-06-01", "departure_on" => "2029-06-02"}),
      op("apply_hotel_credit", "target", %{"amount_cents" => 110})
    ])

    assert Reservations.ledger(~D[2028-01-02]).credit_liability_cents == 110
    submit([op("cancel_group", "target", %{"occurred_on" => "2028-01-02"})])
    assert Reservations.ledger(~D[2028-01-02]).credit_liability_cents == 0
    assert Reservations.guest_credit("guest", ~D[2028-01-02]).available_cents == 0
  end

  test "mixed funding refunds or converts only cash and nonrefundable cancellation consumes credit" do
    for {id, method, date, refund, retained, issued, liability} <- [
          {"cash", "cash", "2027-01-01", 50, 0, 0, 110},
          {"credit", "hotel_credit", "2027-01-01", 0, 0, 55, 165},
          {"late", "cash", "2027-05-03", 0, 50, 0, 0}
        ] do
      # Isolate each scenario while preserving the normal operation path.
      Repo.delete_all(CreditAllocation)
      Repo.delete_all(CreditLot)
      Repo.delete_all(Group)
      issue("source", 100)

      submit([
        open(id),
        op("apply_hotel_credit", id, %{"amount_cents" => 110}),
        op("record_cash_payment", id, %{"amount_cents" => 50})
      ])

      assert Reservations.ledger(~D[2027-01-01]).cash_held_cents == 50

      [result] =
        submit([op("cancel_group", id, %{"occurred_on" => date, "refund_method" => method})])

      assert {result.refunded_cents, result.retained_cents, result.credit_issued_cents} ==
               {refund, retained, issued}

      assert Reservations.ledger(~D[2027-05-03]).credit_liability_cents == liability
    end
  end

  test "credit validation, guest isolation and stale checks leave every table untouched" do
    issue("source", 100)
    submit([open("target"), open("other", %{"guest_id" => "other"})])
    before = snapshot()

    for {operation, code} <- [
          {op("apply_hotel_credit", "target", %{"amount_cents" => 111}), "insufficient_credit"},
          {op("apply_hotel_credit", "target", %{
             "amount_cents" => 1,
             "occurred_on" => "2028-01-02"
           }), "insufficient_credit"},
          {op("apply_hotel_credit", "other", %{"amount_cents" => 1}), "insufficient_credit"},
          {op("apply_hotel_credit", "target", %{"amount_cents" => 0}), "invalid_amount"},
          {op("apply_hotel_credit", "target", %{"amount_cents" => 20_001}),
           "payment_exceeds_outstanding"},
          {op("apply_hotel_credit", "target", %{"amount_cents" => 111, "expected_revision" => 2}),
           "stale_revision"},
          {op("cancel_group", "target", %{
             "refund_method" => "hotel_credit",
             "occurred_on" => "2027-05-03"
           }), "refund_method_not_available"},
          {op("cancel_group", "target", %{"refund_method" => "bogus"}), "invalid_operation"},
          {op("cancel_group", "target", %{"refund_method" => "bogus", "expected_revision" => 2}),
           "stale_revision"}
        ] do
      assert [%{code: ^code}] = submit([operation])
      assert snapshot() == before
    end

    assert [%{revision: 2}, %{code: "stale_revision"}, %{revision: 3}] =
             submit([
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 50,
                 "expected_revision" => 1
               }),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 50,
                 "expected_revision" => 1
               }),
               op("apply_hotel_credit", "target", %{
                 "amount_cents" => 60,
                 "expected_revision" => 2
               })
             ])
  end
end
