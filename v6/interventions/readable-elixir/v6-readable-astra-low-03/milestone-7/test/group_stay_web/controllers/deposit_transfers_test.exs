defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  defp op(type, attrs) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => "2026-10-01"
      },
      attrs
    )
  end

  defp open(id, attrs \\ %{}) do
    op(
      "open_group",
      Map.merge(
        %{
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => id,
          "arrival_on" => "2026-12-01",
          "departure_on" => "2026-12-02",
          "rate_plan" => "flexible",
          "rooms" => Enum.map(1..3, &%{"room_id" => "r#{&1}", "nightly_rate_cents" => 500})
        },
        attrs
      )
    )
  end

  defp transfer(amount, attrs \\ %{}),
    do:
      op(
        "transfer_deposit",
        Map.merge(
          %{"source_group_id" => "s", "destination_group_id" => "d", "amount_cents" => amount},
          attrs
        )
      )

  defp cash(group, id, amount),
    do:
      op("record_cash_payment", %{
        "group_id" => group,
        "operation_id" => id,
        "amount_cents" => amount
      })

  defp submit(ops) when is_list(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{"operations" => ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp submit(op), do: submit([op]) |> hd()

  defp read(path),
    do: build_conn() |> get("/api/v1/" <> path) |> json_response(200) |> Map.fetch!("data")

  defp group(id), do: read("groups/" <> id)
  defp ledger, do: read("ledger?on=2026-10-01")
  defp statement(id), do: read("payments/" <> id)

  test "mixed funding moves newest first, preserves draw order, and replays exactly" do
    payment = cash("s", "p", 80)

    submit([
      open("credit"),
      cash("credit", "seed", 100),
      op("cancel_group", %{"group_id" => "credit", "refund_method" => "hotel_credit"}),
      open("s"),
      open("d")
    ])

    [original, _, _] =
      submit([
        payment,
        op("apply_hotel_credit", %{"group_id" => "s", "amount_cents" => 110}),
        cash("s", "q", 60)
      ])

    before = ledger()
    move = transfer(200, %{"expected_revision" => 4, "destination_expected_revision" => 1})

    assert %{
             "source_revision" => 5,
             "destination_revision" => 2,
             "source_outstanding_deposit_cents" => 250,
             "destination_outstanding_deposit_cents" => 100
           } = result = submit(move)

    assert ledger() == before

    assert Enum.map(group("s")["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {50, 0},
             {0, 0},
             {0, 0}
           ]

    assert Enum.map(group("d")["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {60, 40},
             {30, 70},
             {0, 0}
           ]

    assert statement("p")["held_by_group"] == [
             %{"group_id" => "d", "amount_cents" => 30},
             %{"group_id" => "s", "amount_cents" => 50}
           ]

    assert statement("q")["held_by_group"] == [%{"group_id" => "d", "amount_cents" => 60}]
    refute Map.has_key?(statement("seed"), "held_by_group")
    assert submit(move) == result
    assert submit(payment) == original
    assert submit(Map.put(move, "amount_cents", 201))["code"] == "operation_id_conflict"
    assert ledger() == before
  end

  test "corrections follow global reverse order and increment each changed group once" do
    payment = cash("s", "p", 250)
    [_, _, _, original] = submit([open("s"), open("d"), open("e"), payment])

    submit([
      transfer(120),
      transfer(50, %{"source_group_id" => "d", "destination_group_id" => "e"})
    ])

    reduction =
      op("reduce_cash_payment", %{
        "payment_operation_id" => "p",
        "amount_cents" => 80,
        "expected_revision" => 3
      })

    assert %{"revision" => 4, "outstanding_deposit_cents" => 170} = reduced = submit(reduction)
    assert {group("d")["revision"], group("e")["revision"]} == {4, 3}

    assert statement("p")["held_by_group"] == [
             %{"group_id" => "d", "amount_cents" => 40},
             %{"group_id" => "s", "amount_cents" => 130}
           ]

    assert submit(reduction) == reduced

    assert submit(
             op("charge_back_payment", %{"payment_operation_id" => "p", "expected_revision" => 3})
           )["code"] == "stale_revision"

    assert %{"revision" => 5, "charged_back_cents" => 170} =
             submit(
               op("charge_back_payment", %{
                 "payment_operation_id" => "p",
                 "expected_revision" => 4
               })
             )

    assert {group("d")["revision"], group("e")["revision"]} == {5, 3}
    assert statement("p")["held_by_group"] == []
    assert statement("p")["reduced_cents"] == 80
    assert ledger()["cash_charged_back_cents"] == 170
    assert submit(payment) == original
  end

  test "destination policy settles transferred cash and chargeback reaches settled principal" do
    submit([
      open("s"),
      open("d", %{"rate_plan" => "advance_purchase"}),
      cash("s", "p", 100),
      transfer(100),
      op("cancel_group", %{"group_id" => "d"})
    ])

    assert statement("p")["retained_cents"] == 100
    assert group("s")["revision"] == 3
    assert group("d")["revision"] == 3
    assert submit(op("charge_back_payment", %{"payment_operation_id" => "p"}))["revision"] == 4
    assert group("d")["revision"] == 4
    assert ledger()["cash_retained_cents"] == 0
    assert statement("p")["held_by_group"] == []
  end

  test "transferred credit keeps paused expiry and restores through shortfall absorption" do
    submit([
      open("seed"),
      cash("seed", "p", 100),
      op("cancel_group", %{"group_id" => "seed", "refund_method" => "hotel_credit"}),
      open("s"),
      open("d"),
      op("apply_hotel_credit", %{"group_id" => "s", "amount_cents" => 110})
    ])

    submit(op("charge_back_payment", %{"payment_operation_id" => "p"}))
    assert ledger()["credit_shortfall_cents"] == 110
    before = ledger()
    assert submit(transfer(110, %{"occurred_on" => "2028-01-01"}))["status"] == "applied"
    assert ledger() == before

    submit([
      op("reschedule_group", %{"group_id" => "d", "new_arrival_on" => "2028-12-01"}),
      op("cancel_group", %{"group_id" => "d", "occurred_on" => "2028-01-01"})
    ])

    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert GroupStay.Repo.one(GroupStay.Credit.Lot).unrecovered_clawback_cents == 0
  end

  test "destination conversion rounds once in transferred funding order and is chargeable" do
    submit([open("s"), open("d"), cash("s", "p", 5), cash("s", "q", 5), transfer(10)])

    assert submit(op("cancel_group", %{"group_id" => "d", "refund_method" => "hotel_credit"}))[
             "credit_issued_cents"
           ] == 11

    assert statement("p")["converted_to_credit_cents"] == 5
    assert statement("q")["converted_to_credit_cents"] == 5
    # q arrived first after the reverse draw and owns the rounded six-cent entitlement.
    submit(op("charge_back_payment", %{"payment_operation_id" => "q"}))
    assert ledger()["credit_liability_cents"] == 5
    submit(op("charge_back_payment", %{"payment_operation_id" => "p"}))
    assert ledger()["credit_liability_cents"] == 0
    assert ledger()["cash_charged_back_cents"] == 10
    assert statement("p")["held_by_group"] == []
  end

  test "credit restores to its original lot without a bonus and can be transferred again" do
    submit([
      open("seed"),
      cash("seed", "p", 100),
      op("cancel_group", %{
        "operation_id" => "lot",
        "group_id" => "seed",
        "refund_method" => "hotel_credit"
      }),
      open("s"),
      open("d"),
      op("apply_hotel_credit", %{"group_id" => "s", "amount_cents" => 110}),
      transfer(110)
    ])

    submit(transfer(60, %{"source_group_id" => "d", "destination_group_id" => "s"}))

    assert submit(op("cancel_group", %{"group_id" => "d", "refund_method" => "hotel_credit"}))[
             "credit_issued_cents"
           ] == 0

    assert read("guests/guest/credit?on=2026-10-01")["lots"] == [
             %{
               "source_operation_id" => "lot",
               "remaining_cents" => 50,
               "expires_on" => "2027-10-01"
             }
           ]

    assert ledger()["credit_liability_cents"] == 110
    submit(op("cancel_group", %{"group_id" => "s", "occurred_on" => "2026-11-30"}))
    assert ledger()["credit_liability_cents"] == 50
    # Moving redeemed credit does not mark the cash that originally issued its lot.
    refute Map.has_key?(statement("p"), "held_by_group")
  end

  test "existence and both guards precede domain rules; rejections are atomic and durable" do
    submit([open("s"), open("d"), open("other", %{"guest_id" => "other"}), cash("s", "p", 100)])

    assert %{"code" => "group_not_found", "group_id" => "missing-source"} =
             submit(
               transfer(1, %{
                 "source_group_id" => "missing-source",
                 "destination_group_id" => "missing-destination"
               })
             )

    assert %{"code" => "group_not_found", "group_id" => "missing"} =
             submit(transfer(1, %{"destination_group_id" => "missing", "expected_revision" => 0}))

    assert %{
             "code" => "stale_revision",
             "group_id" => "s",
             "expected_revision" => 0,
             "actual_revision" => 2
           } =
             submit(
               transfer(-1, %{"expected_revision" => 0, "destination_expected_revision" => 0})
             )

    assert %{
             "code" => "stale_revision",
             "group_id" => "d",
             "expected_revision" => 0,
             "actual_revision" => 1
           } =
             submit(
               transfer(-1, %{"expected_revision" => 2, "destination_expected_revision" => 0})
             )

    before = {group("s"), group("d"), ledger(), statement("p")}

    for {amount, attrs, code} <-
          [
            {1, %{"destination_group_id" => "s"}, "invalid_transfer"},
            {1, %{"destination_group_id" => "other"}, "invalid_transfer"},
            {101, %{}, "transfer_exceeds_held_funding"}
          ] ++ Enum.map([0, -1, nil, "1", 1.5], &{&1, %{}, "invalid_amount"}) do
      assert submit(transfer(amount, attrs))["code"] == code
      assert {group("s"), group("d"), ledger(), statement("p")} == before
    end

    submit(cash("d", "full", 300))
    rejected_op = transfer(1)
    assert %{"code" => "transfer_exceeds_outstanding"} = rejected = submit(rejected_op)
    submit(op("reduce_cash_payment", %{"payment_operation_id" => "full", "amount_cents" => 300}))
    assert submit(rejected_op) == rejected
    submit(op("cancel_group", %{"group_id" => "d"}))
    assert %{"code" => "group_not_active", "group_id" => "d"} = submit(transfer(1))

    assert %{"code" => "group_not_active", "group_id" => "d"} =
             submit(transfer(1, %{"source_group_id" => "d", "destination_group_id" => "s"}))
  end
end
