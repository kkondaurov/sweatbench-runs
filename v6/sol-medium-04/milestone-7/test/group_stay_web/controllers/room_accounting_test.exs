defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.{CreditApplication, CreditLot, Group, OperationRecord, Repo}

  defp open(group_id, rooms \\ ["a", "b"]) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-room-accounting",
      "property_id" => "ams-canal",
      "arrival_on" => "2027-12-10",
      "departure_on" => "2027-12-11",
      "rate_plan" => "flexible",
      "rooms" => Enum.map(rooms, &%{"room_id" => &1, "nightly_rate_cents" => 10_000})
    }
  end

  defp pay(id, group_id, amount) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp submit(operations) do
    build_conn()
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(id) do
    get(build_conn(), "/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")
  end

  test "funding fills rooms in order and selected cancellation preserves the others" do
    [_, _] = submit([open("partial"), pay("pay-partial", "partial", 2_500)])

    assert group("partial")["rooms"] == [
             %{
               "room_id" => "a",
               "nightly_rate_cents" => 10_000,
               "status" => "active",
               "lodging_total_cents" => 10_000,
               "deposit_due_cents" => 2_000,
               "cash_paid_cents" => 2_000,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "b",
               "nightly_rate_cents" => 10_000,
               "status" => "active",
               "lodging_total_cents" => 10_000,
               "deposit_due_cents" => 2_000,
               "cash_paid_cents" => 500,
               "credit_paid_cents" => 0
             }
           ]

    [cancelled] =
      submit([
        %{
          "operation_id" => "cancel-a",
          "type" => "cancel_rooms",
          "occurred_on" => "2027-10-01",
          "group_id" => "partial",
          "room_ids" => ["a"]
        }
      ])

    assert cancelled["cancelled_room_ids"] == ["a"]
    assert cancelled["refunded_cents"] == 2_000

    data = group("partial")
    assert data["status"] == "active"
    assert data["lodging_total_cents"] == 10_000
    assert data["deposit_due_cents"] == 2_000
    assert data["deposit_paid_cents"] == 500
    assert data["outstanding_deposit_cents"] == 1_500
    assert Enum.map(data["rooms"], & &1["status"]) == ["cancelled", "active"]
  end

  test "cancel_rooms validates the complete distinct active selection and returns original order" do
    submit([open("selection")])

    for {id, room_ids} <- [{"duplicate", ["a", "a"]}, {"missing", ["nope"]}, {"empty", []}] do
      assert [%{"code" => "invalid_rooms"}] =
               submit([
                 %{
                   "operation_id" => id,
                   "type" => "cancel_rooms",
                   "occurred_on" => "2027-10-01",
                   "group_id" => "selection",
                   "room_ids" => room_ids
                 }
               ])
    end

    assert [result] =
             submit([
               %{
                 "operation_id" => "valid-selection",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2027-10-01",
                 "group_id" => "selection",
                 "room_ids" => ["b", "a"]
               }
             ])

    assert result["cancelled_room_ids"] == ["a", "b"]
    assert group("selection")["status"] == "cancelled"
  end

  test "successive reductions remove only the target payment in reverse fill order" do
    submit([open("reductions"), pay("pay-reduced", "reductions", 2_500)])

    [first, second] =
      submit([
        %{
          "operation_id" => "reduce-one",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2027-01-03",
          "payment_operation_id" => "pay-reduced",
          "amount_cents" => 600,
          "expected_revision" => 2
        },
        %{
          "operation_id" => "reduce-two",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2027-01-04",
          "payment_operation_id" => "pay-reduced",
          "amount_cents" => 1_900,
          "expected_revision" => 3
        }
      ])

    assert first["outstanding_deposit_cents"] == 2_100
    assert second["outstanding_deposit_cents"] == 4_000

    assert get(build_conn(), ~p"/api/v1/payments/pay-reduced") |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "pay-reduced",
               "original_group_id" => "reductions",
               "recorded_cents" => 2_500,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 2_500,
               "charged_back_cents" => 0
             }
           }

    assert [%{"code" => "payment_not_reducible"}] =
             submit([
               %{
                 "operation_id" => "reduce-empty",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2027-01-05",
                 "payment_operation_id" => "pay-reduced",
                 "amount_cents" => 1
               }
             ])
  end

  test "chargeback reclassifies refunded and held cash and is durably idempotent" do
    submit([open("charge"), pay("pay-charge", "charge", 2_500)])

    submit([
      %{
        "operation_id" => "cancel-charge-a",
        "type" => "cancel_rooms",
        "occurred_on" => "2027-10-01",
        "group_id" => "charge",
        "room_ids" => ["a"]
      }
    ])

    operation = %{
      "operation_id" => "chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2027-10-02",
      "payment_operation_id" => "pay-charge",
      "expected_revision" => 3
    }

    [result] = submit([operation])
    assert result["charged_back_cents"] == 2_500
    assert result["outstanding_deposit_cents"] == 2_000
    assert submit([operation]) == [result]

    statement =
      get(build_conn(), ~p"/api/v1/payments/pay-charge")
      |> json_response(200)
      |> Map.fetch!("data")

    assert statement["charged_back_cents"] == 2_500
    assert statement["held_cents"] == 0
    assert statement["refunded_cents"] == 0

    ledger = get(build_conn(), ~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_charged_back_cents"] == 2_500
    assert ledger["cash_refunded_cents"] == 0
  end

  test "converted-payment clawback creates and later absorbs a credit shortfall" do
    submit([
      open("credit-source", ["source"]),
      pay("credit-pay-one", "credit-source", 100),
      pay("credit-pay-two", "credit-source", 100),
      %{
        "operation_id" => "convert-source",
        "type" => "cancel_group",
        "occurred_on" => "2027-10-01",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open("credit-target", ["target"]),
      %{
        "operation_id" => "spend-converted",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-10-02",
        "group_id" => "credit-target",
        "amount_cents" => 220
      }
    ])

    [charged] =
      submit([
        %{
          "operation_id" => "charge-converted",
          "type" => "charge_back_payment",
          "occurred_on" => "2027-10-03",
          "payment_operation_id" => "credit-pay-one"
        }
      ])

    assert charged["charged_back_cents"] == 100

    ledger =
      get(build_conn(), ~p"/api/v1/ledger?on=2027-10-03")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger["credit_shortfall_cents"] == 110
    assert ledger["credit_liability_cents"] == 220

    submit([
      %{
        "operation_id" => "restore-shortfall",
        "type" => "cancel_group",
        "occurred_on" => "2027-10-04",
        "group_id" => "credit-target"
      }
    ])

    ledger =
      get(build_conn(), ~p"/api/v1/ledger?on=2027-10-04")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger["credit_shortfall_cents"] == 0
    assert ledger["credit_liability_cents"] == 110
  end

  test "payment reads distinguish missing and non-payment durable records" do
    submit([open("reconcile")])

    assert get(build_conn(), ~p"/api/v1/payments/no-such-operation") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}

    assert get(build_conn(), ~p"/api/v1/payments/open-reconcile") |> json_response(422) ==
             %{"error" => %{"code" => "payment_not_reconcilable"}}
  end

  test "pre-release funding is reconstructed senior-first without changing balances" do
    submit([open("upgraded", ["a", "b", "c"])])
    group_row = Repo.get!(Group, "upgraded")

    rooms =
      Repo.all(from r in GroupStay.Room, where: r.group_id == "upgraded", order_by: r.position)

    legacy_lot =
      Repo.insert!(%CreditLot{
        guest_id: group_row.guest_id,
        source_operation_id: "legacy-credit",
        remaining_cents: 0,
        expires_on: ~D[2028-12-31]
      })

    durable_lot =
      Repo.insert!(%CreditLot{
        guest_id: group_row.guest_id,
        source_operation_id: "durable-credit-source",
        remaining_cents: 0,
        expires_on: ~D[2028-12-31]
      })

    Repo.insert!(%CreditApplication{
      group_id: group_row.id,
      credit_lot_id: legacy_lot.id,
      amount_cents: 1_000
    })

    Repo.insert!(%CreditApplication{
      group_id: group_row.id,
      credit_lot_id: durable_lot.id,
      amount_cents: 1_000
    })

    Repo.insert!(%OperationRecord{
      operation_id: "upgrade-pay",
      operation_type: "record_cash_payment",
      submission: %{"operation_id" => "upgrade-pay"},
      result: %{
        "operation_id" => "upgrade-pay",
        "status" => "applied",
        "group_id" => "upgraded",
        "amount_cents" => 1_000
      }
    })

    Repo.insert!(%OperationRecord{
      operation_id: "upgrade-credit",
      operation_type: "apply_hotel_credit",
      submission: %{"operation_id" => "upgrade-credit"},
      result: %{
        "operation_id" => "upgrade-credit",
        "status" => "applied",
        "group_id" => "upgraded",
        "amount_cents" => 1_000
      }
    })

    group_row
    |> Ecto.Changeset.change(
      cash_paid_cents: 2_500,
      credit_paid_cents: 2_000,
      deposit_paid_cents: 4_500
    )
    |> Repo.update!()

    before_lots = {legacy_lot.remaining_cents, durable_lot.remaining_cents}
    data = group("upgraded")

    assert Enum.map(data["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) ==
             [{1_500, 500}, {1_000, 1_000}, {0, 500}]

    assert data["deposit_paid_cents"] == 4_500

    assert {Repo.get!(CreditLot, legacy_lot.id).remaining_cents,
            Repo.get!(CreditLot, durable_lot.id).remaining_cents} == before_lots

    assert Enum.map(rooms, & &1.status) == ["active", "active", "active"]
  end
end
