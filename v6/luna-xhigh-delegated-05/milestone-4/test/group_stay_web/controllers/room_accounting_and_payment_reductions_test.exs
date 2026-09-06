defmodule GroupStayWeb.RoomAccountingAndPaymentReductionsTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Cash.PaymentState
  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Ledger.Total
  alias GroupStay.Operations
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-room-accounting",
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: "room-accounting",
        guest_id: "room-guest",
        property_id: "ams-canal",
        arrival_on: "2027-02-01",
        departure_on: "2027-02-02",
        rate_plan: "flexible",
        rooms: [
          %{room_id: "room-a", nightly_rate_cents: 5_000},
          %{room_id: "room-b", nightly_rate_cents: 5_000}
        ]
      },
      overrides
    )
  end

  defp payment(operation_id, amount_cents) do
    payment_for("room-accounting", operation_id, amount_cents)
  end

  defp payment_for(group_id, operation_id, amount_cents) do
    %{
      operation_id: operation_id,
      type: "record_cash_payment",
      occurred_on: "2026-10-03",
      group_id: group_id,
      amount_cents: amount_cents
    }
  end

  test "allocates cash by room and settles only selected rooms", %{conn: conn} do
    submit(conn, [open_operation(), payment("pay-a", 1_500), payment("pay-b", 500)])
    |> json_response(200)

    assert get(conn, "/api/v1/groups/room-accounting")
           |> json_response(200)
           |> get_in(["data", "rooms"]) == [
             %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 5_000,
               "status" => "active",
               "lodging_cents" => 5_000,
               "deposit_due_cents" => 1_000,
               "cash_paid_cents" => 1_000,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "room-b",
               "nightly_rate_cents" => 5_000,
               "status" => "active",
               "lodging_cents" => 5_000,
               "deposit_due_cents" => 1_000,
               "cash_paid_cents" => 1_000,
               "credit_paid_cents" => 0
             }
           ]

    result =
      submit(conn, [
        %{
          operation_id: "cancel-room-b",
          type: "cancel_rooms",
          occurred_on: "2027-01-01",
          group_id: "room-accounting",
          room_ids: ["room-b"],
          refund_method: "cash",
          expected_revision: 3
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert result == %{
             "operation_id" => "cancel-room-b",
             "status" => "applied",
             "group_id" => "room-accounting",
             "cancelled_room_ids" => ["room-b"],
             "refunded_cents" => 1_000,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 4
           }

    group = get(conn, "/api/v1/groups/room-accounting") |> json_response(200)

    assert group["data"]["status"] == "active"
    assert group["data"]["deposit_due_cents"] == 1_000
    assert group["data"]["cash_paid_cents"] == 1_000
    assert group["data"]["outstanding_deposit_cents"] == 0
    assert Enum.at(group["data"]["rooms"], 1)["status"] == "cancelled"
    assert Enum.at(group["data"]["rooms"], 1)["cash_paid_cents"] == 0
    assert Enum.at(group["data"]["rooms"], 1)["credit_paid_cents"] == 0

    assert get(conn, "/api/v1/payments/pay-a") |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "pay-a",
               "original_group_id" => "room-accounting",
               "recorded_cents" => 1_500,
               "held_cents" => 1_000,
               "refunded_cents" => 500,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
           }
  end

  test "reduces held cash in reverse fill order and composes reductions", %{conn: conn} do
    submit(conn, [open_operation(), payment("pay-reduce", 1_500)]) |> json_response(200)

    first =
      submit(conn, [
        %{
          operation_id: "reduce-1",
          type: "reduce_cash_payment",
          payment_operation_id: "pay-reduce",
          amount_cents: 600,
          expected_revision: 2
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert first["outstanding_deposit_cents"] == 1_100
    assert first["revision"] == 3

    group = get(conn, "/api/v1/groups/room-accounting") |> json_response(200)
    assert Enum.map(group["data"]["rooms"], & &1["cash_paid_cents"]) == [900, 0]

    second =
      submit(conn, [
        %{
          operation_id: "reduce-2",
          type: "reduce_cash_payment",
          payment_operation_id: "pay-reduce",
          amount_cents: 900,
          expected_revision: 3
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert second["outstanding_deposit_cents"] == 2_000

    rejected =
      submit(conn, [
        %{
          operation_id: "reduce-3",
          type: "reduce_cash_payment",
          payment_operation_id: "pay-reduce",
          amount_cents: 1
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert rejected["code"] == "payment_not_reducible"

    assert get(conn, "/api/v1/payments/pay-reduce")
           |> json_response(200)
           |> get_in(["data", "reduced_cents"]) == 1_500

    assert get(conn, "/api/v1/ledger") |> json_response(200) |> get_in(["data"]) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 1_500,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }
  end

  test "chargeback moves a converted payment through credit shortfall and absorption", %{
    conn: conn
  } do
    submit(conn, [
      open_operation(%{
        group_id: "source",
        guest_id: "chargeback-guest",
        operation_id: "open-source"
      }),
      payment_for("source", "pay-source", 1_000)
    ])
    |> json_response(200)

    submit(conn, [
      %{
        operation_id: "cancel-source",
        type: "cancel_group",
        occurred_on: "2027-01-01",
        group_id: "source",
        refund_method: "hotel_credit"
      }
    ])
    |> json_response(200)

    submit(conn, [
      open_operation(%{
        group_id: "target",
        guest_id: "chargeback-guest",
        operation_id: "open-target"
      }),
      %{
        operation_id: "apply-target",
        type: "apply_hotel_credit",
        occurred_on: "2027-01-01",
        group_id: "target",
        amount_cents: 1_100
      }
    ])
    |> json_response(200)

    result =
      submit(conn, [
        %{
          operation_id: "chargeback-source",
          type: "charge_back_payment",
          payment_operation_id: "pay-source",
          expected_revision: 3
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert result["charged_back_cents"] == 1_000
    assert result["revision"] == 4

    assert get(conn, "/api/v1/groups/target")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 2

    assert get(conn, "/api/v1/ledger") |> json_response(200) |> get_in(["data"]) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 1_000,
             "credit_liability_cents" => 1_100,
             "credit_shortfall_cents" => 1_100
           }

    submit(conn, [
      %{
        operation_id: "cancel-target",
        type: "cancel_group",
        occurred_on: "2027-01-01",
        group_id: "target"
      }
    ])
    |> json_response(200)

    assert get(conn, "/api/v1/ledger")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 0

    assert get(conn, "/api/v1/ledger")
           |> json_response(200)
           |> get_in(["data", "credit_shortfall_cents"]) == 0
  end

  test "reconciliation and reductions keep original durable results immutable", %{conn: conn} do
    original =
      submit(conn, [open_operation(), payment("pay-immutable", 500)])
      |> json_response(200)
      |> get_in(["results", Access.at(1)])

    submit(conn, [
      %{
        operation_id: "reduce-immutable",
        type: "reduce_cash_payment",
        payment_operation_id: "pay-immutable",
        amount_cents: 100
      }
    ])
    |> json_response(200)

    assert submit(conn, [payment("pay-immutable", 500)])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == original

    assert get(conn, "/api/v1/operations/pay-immutable") |> json_response(200) == %{
             "data" => original
           }

    state_before = Repo.get_by!(PaymentState, payment_operation_id: "pay-immutable")

    assert get(conn, "/api/v1/payments/pay-immutable")
           |> json_response(200)
           |> get_in(["data", "held_cents"]) == 400

    assert Repo.get_by!(PaymentState, payment_operation_id: "pay-immutable") == state_before

    assert get(conn, "/api/v1/payments/unknown-payment") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  test "chargeback reclassifies refunded cash and preserves reduced cash", %{conn: conn} do
    submit(conn, [open_operation(), payment("pay-refunded", 1_000)]) |> json_response(200)

    submit(conn, [
      %{
        operation_id: "cancel-refunded",
        type: "cancel_group",
        occurred_on: "2027-01-01",
        group_id: "room-accounting"
      }
    ])
    |> json_response(200)

    result =
      submit(conn, [
        %{
          operation_id: "charge-refunded",
          type: "charge_back_payment",
          payment_operation_id: "pay-refunded",
          expected_revision: 3
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert result["charged_back_cents"] == 1_000
    assert result["revision"] == 4

    assert get(conn, "/api/v1/payments/pay-refunded") |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "pay-refunded",
               "original_group_id" => "room-accounting",
               "recorded_cents" => 1_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 1_000
             }
           }

    assert get(conn, "/api/v1/ledger") |> json_response(200) |> get_in(["data"]) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 1_000,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }

    assert submit(conn, [
             %{
               operation_id: "charge-refunded-retry",
               type: "charge_back_payment",
               payment_operation_id: "pay-refunded"
             }
           ])
           |> json_response(200)
           |> get_in(["results", Access.at(0), "code"]) == "payment_not_chargeable"
  end

  test "entitlement clawback is per payment and creates a current shortfall", %{conn: conn} do
    submit(conn, [
      open_operation(%{
        group_id: "source",
        guest_id: "entitlement-guest",
        operation_id: "open-source"
      }),
      payment_for("source", "pay-one", 1),
      payment_for("source", "pay-two", 2)
    ])
    |> json_response(200)

    submit(conn, [
      %{
        operation_id: "cancel-source-credit",
        type: "cancel_group",
        occurred_on: "2027-01-01",
        group_id: "source",
        refund_method: "hotel_credit"
      },
      open_operation(%{
        group_id: "target",
        guest_id: "entitlement-guest",
        operation_id: "open-target"
      }),
      %{
        operation_id: "apply-all-credit",
        type: "apply_hotel_credit",
        occurred_on: "2027-01-01",
        group_id: "target",
        amount_cents: 3
      }
    ])
    |> json_response(200)

    result =
      submit(conn, [
        %{
          operation_id: "charge-second",
          type: "charge_back_payment",
          payment_operation_id: "pay-two",
          expected_revision: 4
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert result["charged_back_cents"] == 2

    assert get(conn, "/api/v1/ledger")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 3

    assert get(conn, "/api/v1/ledger")
           |> json_response(200)
           |> get_in(["data", "credit_shortfall_cents"]) == 2
  end

  test "backfills legacy aggregate cash before durable payment funding", %{conn: conn} do
    group =
      Repo.insert!(%Group{
        group_id: "legacy-group",
        guest_id: "legacy-guest",
        property_id: "ams-canal",
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2027-02-01],
        departure_on: ~D[2027-02-02],
        rate_plan: "flexible",
        policy_version: "flex-14",
        status: "active",
        lodging_total_cents: 10_000,
        deposit_due_cents: 2_000,
        deposit_paid_cents: 1_500,
        cash_paid_cents: 1_500,
        credit_paid_cents: 0,
        revision: 2,
        accounting_version: 0
      })

    Repo.insert!(%Room{
      group_id: group.id,
      room_id: "room-a",
      nightly_rate_cents: 5_000,
      position: 0
    })

    Repo.insert!(%Room{
      group_id: group.id,
      room_id: "room-b",
      nightly_rate_cents: 5_000,
      position: 1
    })

    Repo.insert!(%Record{
      operation_id: "legacy-payment",
      operation_type: "record_cash_payment",
      payload_json: Jason.encode!(%{operation_id: "legacy-payment"}),
      result_json:
        Jason.encode!(%{
          operation_id: "legacy-payment",
          status: "applied",
          group_id: "legacy-group",
          amount_cents: 500
        })
    })

    Repo.update!(Ecto.Changeset.change(Repo.get!(Total, 1), cash_held_cents: 1_500))

    ledger_before = Repo.get!(Total, 1)
    assert :ok = Operations.backfill_legacy_room_accounting!()
    assert Repo.get!(Total, 1) == ledger_before

    submit(conn, [
      %{
        operation_id: "legacy-next",
        type: "record_cash_payment",
        occurred_on: "2026-10-03",
        group_id: "legacy-group",
        amount_cents: 500
      }
    ])
    |> json_response(200)

    assert get(conn, "/api/v1/groups/legacy-group")
           |> json_response(200)
           |> get_in(["data", "rooms"]) == [
             %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 5_000,
               "status" => "active",
               "lodging_cents" => 5_000,
               "deposit_due_cents" => 1_000,
               "cash_paid_cents" => 1_000,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "room-b",
               "nightly_rate_cents" => 5_000,
               "status" => "active",
               "lodging_cents" => 5_000,
               "deposit_due_cents" => 1_000,
               "cash_paid_cents" => 1_000,
               "credit_paid_cents" => 0
             }
           ]

    assert get(conn, "/api/v1/payments/legacy-payment")
           |> json_response(200)
           |> get_in(["data", "held_cents"]) == 500

    assert get(conn, "/api/v1/payments/legacy-next")
           |> json_response(200)
           |> get_in(["data", "held_cents"]) == 500
  end
end
