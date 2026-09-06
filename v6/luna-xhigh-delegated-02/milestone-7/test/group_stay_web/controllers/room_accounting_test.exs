defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Groups.Group
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  defp json_post(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 500},
          %{"room_id" => "room-b", "nightly_rate_cents" => 500}
        ]
      },
      overrides
    )
  end

  test "allocates funding by room order and settles only selected rooms", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}, pay_1, pay_2, cancellation]} =
             json_post(conn, %{
               "operations" => [
                 open_operation(),
                 %{
                   "operation_id" => "pay-1",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "group-81",
                   "amount_cents" => 150
                 },
                 %{
                   "operation_id" => "pay-2",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-05",
                   "group_id" => "group-81",
                   "amount_cents" => 30
                 },
                 %{
                   "operation_id" => "cancel-room",
                   "type" => "cancel_rooms",
                   "occurred_on" => "2026-10-06",
                   "group_id" => "group-81",
                   "room_ids" => ["room-b"]
                 }
               ]
             })
             |> json_response(200)

    assert pay_1["outstanding_deposit_cents"] == 50
    assert pay_2["outstanding_deposit_cents"] == 20
    assert cancellation["cancelled_room_ids"] == ["room-b"]
    assert cancellation["refunded_cents"] == 80

    assert %{"data" => group} = get(build_conn(), "/api/v1/groups/group-81") |> json_response(200)
    assert group["status"] == "active"
    assert group["deposit_due_cents"] == 100
    assert group["cash_paid_cents"] == 100
    assert group["outstanding_deposit_cents"] == 0

    assert Enum.map(group["rooms"], &{&1["room_id"], &1["status"], &1["cash_paid_cents"]}) ==
             [{"room-a", "active", 100}, {"room-b", "cancelled", 0}]

    assert %{"data" => ledger} = get(build_conn(), "/api/v1/ledger") |> json_response(200)
    assert ledger["cash_held_cents"] == 100
    assert ledger["cash_refunded_cents"] == 80
  end

  test "reductions remove held cash from the reverse room fill order and reconcile it", %{
    conn: conn
  } do
    assert %{"results" => [_, payment, reduction]} =
             json_post(conn, %{
               "operations" => [
                 open_operation(),
                 %{
                   "operation_id" => "pay-1",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "group-81",
                   "amount_cents" => 150
                 },
                 %{
                   "operation_id" => "reduce-1",
                   "type" => "reduce_cash_payment",
                   "occurred_on" => "2026-10-05",
                   "group_id" => "group-81",
                   "payment_operation_id" => "pay-1",
                   "amount_cents" => 20
                 }
               ]
             })
             |> json_response(200)

    assert payment["revision"] == 2
    assert reduction["amount_cents"] == 20
    assert reduction["outstanding_deposit_cents"] == 70

    assert %{"data" => group} = get(build_conn(), "/api/v1/groups/group-81") |> json_response(200)

    assert Enum.map(group["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) ==
             [{"room-a", 100}, {"room-b", 30}]

    assert %{"data" => payment_view} =
             get(build_conn(), "/api/v1/payments/pay-1") |> json_response(200)

    assert payment_view == %{
             "payment_operation_id" => "pay-1",
             "original_group_id" => "group-81",
             "recorded_cents" => 150,
             "held_cents" => 130,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 20,
             "charged_back_cents" => 0
           }
  end

  test "chargebacks reclassify held cash without rewriting the original payment", %{conn: conn} do
    assert %{"results" => [_, payment, chargeback]} =
             json_post(conn, %{
               "operations" => [
                 open_operation(),
                 %{
                   "operation_id" => "pay-1",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "group-81",
                   "amount_cents" => 150
                 },
                 %{
                   "operation_id" => "chargeback-1",
                   "type" => "charge_back_payment",
                   "occurred_on" => "2026-10-05",
                   "payment_operation_id" => "pay-1"
                 }
               ]
             })
             |> json_response(200)

    assert payment["revision"] == 2
    assert chargeback["charged_back_cents"] == 150
    assert chargeback["revision"] == 3

    assert %{"data" => group} = get(build_conn(), "/api/v1/groups/group-81") |> json_response(200)
    assert group["cash_paid_cents"] == 0
    assert group["outstanding_deposit_cents"] == 200

    assert %{"data" => payment_view} =
             get(build_conn(), "/api/v1/payments/pay-1") |> json_response(200)

    assert payment_view["held_cents"] == 0
    assert payment_view["charged_back_cents"] == 150
    assert payment_view["recorded_cents"] == 150

    assert %{"data" => ledger} = get(build_conn(), "/api/v1/ledger") |> json_response(200)
    assert ledger["cash_charged_back_cents"] == 150
    assert ledger["cash_held_cents"] == 0
  end

  test "credit uses room order, restores selected rooms, and tracks chargeback shortfall", %{
    conn: conn
  } do
    source = open_operation(%{"rooms" => [%{"room_id" => "source", "nightly_rate_cents" => 500}]})

    target =
      open_operation(%{
        "operation_id" => "open-target",
        "group_id" => "group-82",
        "arrival_on" => "2026-12-20",
        "departure_on" => "2026-12-21",
        "rooms" => [
          %{"room_id" => "target-a", "nightly_rate_cents" => 500},
          %{"room_id" => "target-b", "nightly_rate_cents" => 500}
        ]
      })

    assert %{"results" => [_, _, _, source_cancel, _, apply]} =
             json_post(conn, %{
               "operations" => [
                 source,
                 %{
                   "operation_id" => "pay-source-a",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "group-81",
                   "amount_cents" => 50
                 },
                 %{
                   "operation_id" => "pay-source-b",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "group-81",
                   "amount_cents" => 50
                 },
                 %{
                   "operation_id" => "source-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-10-05",
                   "group_id" => "group-81",
                   "refund_method" => "hotel_credit"
                 },
                 target,
                 %{
                   "operation_id" => "apply-credit",
                   "type" => "apply_hotel_credit",
                   "occurred_on" => "2026-10-06",
                   "group_id" => "group-82",
                   "amount_cents" => 110
                 }
               ]
             })
             |> json_response(200)

    assert source_cancel["credit_issued_cents"] == 110
    assert apply["outstanding_deposit_cents"] == 90

    assert %{"data" => target_group} =
             get(build_conn(), "/api/v1/groups/group-82") |> json_response(200)

    assert Enum.map(target_group["rooms"], &{&1["room_id"], &1["credit_paid_cents"]}) ==
             [{"target-a", 100}, {"target-b", 10}]

    assert %{"results" => [chargeback]} =
             json_post(conn, %{
               "operations" => [
                 %{
                   "operation_id" => "chargeback-source",
                   "type" => "charge_back_payment",
                   "occurred_on" => "2026-10-07",
                   "payment_operation_id" => "pay-source-a"
                 }
               ]
             })
             |> json_response(200)

    assert chargeback["charged_back_cents"] == 50

    assert %{"data" => ledger} = get(build_conn(), "/api/v1/ledger") |> json_response(200)
    assert ledger["credit_liability_cents"] == 110
    assert ledger["credit_shortfall_cents"] == 55

    assert %{"results" => [cancel_target]} =
             json_post(conn, %{
               "operations" => [
                 %{
                   "operation_id" => "cancel-target-room",
                   "type" => "cancel_rooms",
                   "occurred_on" => "2026-10-08",
                   "group_id" => "group-82",
                   "room_ids" => ["target-a"]
                 }
               ]
             })
             |> json_response(200)

    assert cancel_target["cancelled_room_ids"] == ["target-a"]

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2026-10-08")
           |> json_response(200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 45,
               "lots" => [
                 %{
                   "source_operation_id" => "source-cancel",
                   "remaining_cents" => 45,
                   "expires_on" => "2027-10-06"
                 }
               ]
             }
           }

    assert %{"data" => ledger} = get(build_conn(), "/api/v1/ledger") |> json_response(200)
    assert ledger["credit_shortfall_cents"] == 0
  end

  test "invalid selected rooms are rejected and repeated cancellations are idempotent", %{
    conn: conn
  } do
    assert %{"results" => [%{"status" => "applied"}]} =
             json_post(conn, %{"operations" => [open_operation()]}) |> json_response(200)

    invalid = %{
      "operation_id" => "bad-cancel",
      "type" => "cancel_rooms",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "room_ids" => ["room-a", "room-a"]
    }

    assert %{"results" => [%{"code" => "invalid_rooms"}]} =
             json_post(conn, %{"operations" => [invalid]}) |> json_response(200)

    cancellation =
      Map.put(invalid, "operation_id", "cancel-one") |> Map.put("room_ids", ["room-a"])

    assert %{"results" => [first]} =
             json_post(conn, %{"operations" => [cancellation]}) |> json_response(200)

    assert %{"results" => [retry]} =
             json_post(conn, %{"operations" => [cancellation]}) |> json_response(200)

    assert retry == first
  end

  test "a chargeback can reclassify a refunded payment on a cancelled group", %{conn: conn} do
    assert %{"results" => [_, _, refund]} =
             json_post(conn, %{
               "operations" => [
                 open_operation(%{
                   "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 500}]
                 }),
                 %{
                   "operation_id" => "pay-1",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "group-81",
                   "amount_cents" => 100
                 },
                 %{
                   "operation_id" => "cancel-1",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-10-05",
                   "group_id" => "group-81"
                 }
               ]
             })
             |> json_response(200)

    assert refund["refunded_cents"] == 100

    assert %{"results" => [chargeback]} =
             json_post(conn, %{
               "operations" => [
                 %{
                   "operation_id" => "chargeback-1",
                   "type" => "charge_back_payment",
                   "occurred_on" => "2026-10-06",
                   "payment_operation_id" => "pay-1",
                   "expected_revision" => 3
                 }
               ]
             })
             |> json_response(200)

    assert chargeback["charged_back_cents"] == 100
    assert chargeback["revision"] == 4

    assert %{"data" => payment} =
             get(build_conn(), "/api/v1/payments/pay-1") |> json_response(200)

    assert payment["refunded_cents"] == 0
    assert payment["charged_back_cents"] == 100

    assert %{"data" => ledger} = get(build_conn(), "/api/v1/ledger") |> json_response(200)
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 100
  end

  test "a pre-room-accounting durable payment is backfilled before reduction", %{conn: conn} do
    rooms = [%{"room_id" => "room-a", "nightly_rate_cents" => 500}]

    {:ok, group} =
      %Group{}
      |> Group.changeset(%{
        group_id: "legacy-group",
        guest_id: "guest-22",
        property_id: "ams-canal",
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-11],
        rate_plan: "flexible",
        policy_version: "flex-14",
        rooms_json: Jason.encode!(rooms),
        lodging_total_cents: 500,
        deposit_due_cents: 100,
        deposit_paid_cents: 100,
        cash_paid_cents: 100,
        credit_paid_cents: 0,
        room_accounting_initialized: false,
        status: "active",
        revision: 1
      })
      |> Repo.insert()

    assert group.group_id == "legacy-group"

    old_payload = %{
      "operation_id" => "old-pay",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "legacy-group",
      "amount_cents" => 100
    }

    old_result = %{
      "operation_id" => "old-pay",
      "status" => "applied",
      "group_id" => "legacy-group",
      "amount_cents" => 100,
      "outstanding_deposit_cents" => 0,
      "revision" => 2
    }

    Repo.insert!(%Operation{
      operation_id: "old-pay",
      operation_type: "record_cash_payment",
      commit_sequence: 1,
      payload_json: Jason.encode!(old_payload),
      result_json: Jason.encode!(old_result)
    })

    assert %{"results" => [reduction]} =
             json_post(conn, %{
               "operations" => [
                 %{
                   "operation_id" => "reduce-old",
                   "type" => "reduce_cash_payment",
                   "payment_operation_id" => "old-pay",
                   "amount_cents" => 20
                 }
               ]
             })
             |> json_response(200)

    assert reduction["code"] == nil
    assert reduction["amount_cents"] == 20

    assert %{"data" => payment} =
             get(build_conn(), "/api/v1/payments/old-pay") |> json_response(200)

    assert payment["held_cents"] == 80
    assert payment["reduced_cents"] == 20
  end

  test "new funding skips rooms cancelled by an earlier partial settlement", %{conn: conn} do
    assert %{"results" => [_, cancellation, payment]} =
             json_post(conn, %{
               "operations" => [
                 open_operation(),
                 %{
                   "operation_id" => "cancel-a",
                   "type" => "cancel_rooms",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "group-81",
                   "room_ids" => ["room-a"]
                 },
                 %{
                   "operation_id" => "pay-b",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-05",
                   "group_id" => "group-81",
                   "amount_cents" => 100,
                   "expected_revision" => 2
                 }
               ]
             })
             |> json_response(200)

    assert cancellation["cancelled_room_ids"] == ["room-a"]
    assert payment["outstanding_deposit_cents"] == 0

    assert %{"data" => group} = get(build_conn(), "/api/v1/groups/group-81") |> json_response(200)

    assert Enum.map(group["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) ==
             [{"room-a", 0}, {"room-b", 100}]
  end

  test "payment correction rejection codes distinguish target and amount failures", %{conn: conn} do
    assert %{"results" => [_, _]} =
             json_post(conn, %{
               "operations" => [
                 open_operation(%{
                   "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 500}]
                 }),
                 %{
                   "operation_id" => "pay-1",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "group-81",
                   "amount_cents" => 100
                 }
               ]
             })
             |> json_response(200)

    requests = [
      %{
        "operation_id" => "missing-target",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "missing",
        "amount_cents" => 1
      },
      %{
        "operation_id" => "bad-amount",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "pay-1",
        "amount_cents" => 0
      },
      %{
        "operation_id" => "too-much",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "pay-1",
        "amount_cents" => 101
      },
      %{
        "operation_id" => "reduce-all",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "pay-1",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "already-reduced",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "pay-1",
        "amount_cents" => 1
      },
      %{
        "operation_id" => "not-a-payment",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "open-1",
        "amount_cents" => 1
      }
    ]

    assert %{"results" => results} =
             json_post(conn, %{"operations" => requests}) |> json_response(200)

    assert Enum.map(results, & &1["code"]) == [
             "operation_not_found",
             "invalid_amount",
             "reduction_exceeds_held_cash",
             nil,
             "payment_not_reducible",
             "payment_not_reducible"
           ]
  end
end
