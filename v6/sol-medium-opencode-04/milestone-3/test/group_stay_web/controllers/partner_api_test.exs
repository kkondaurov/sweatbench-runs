defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase
  import Ecto.Query

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
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp post_operations(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "opens and reads a group with ordered rooms and calculated totals", %{conn: conn} do
    assert [result] = post_operations(conn, [open_operation()])

    assert result == %{
             "operation_id" => "open-1",
             "status" => "applied",
             "group_id" => "group-81",
             "deposit_due_cents" => 19_500,
             "revision" => 1
           }

    data = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

    assert data["rooms"] == [
             %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
             %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
           ]

    assert data["lodging_total_cents"] == 97_500
    assert data["deposit_due_cents"] == 19_500
    assert data["deposit_paid_cents"] == 0
    assert data["outstanding_deposit_cents"] == 19_500
    assert data["revision"] == 1
    assert data["booked_on"] == "2026-10-03"
    assert data["status"] == "active"
  end

  test "advance purchase requires the full lodging amount", %{conn: conn} do
    op = open_operation(%{"rate_plan" => "advance_purchase"})
    assert [%{"deposit_due_cents" => 97_500}] = post_operations(conn, [op])
  end

  test "rounds flexible deposits per room before summing", %{conn: conn} do
    op =
      open_operation(%{
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 3},
          %{"room_id" => "room-b", "nightly_rate_cents" => 3}
        ]
      })

    assert [%{"deposit_due_cents" => 2}] = post_operations(conn, [op])
  end

  test "validates opening fields without persisting rejected groups", %{conn: conn} do
    operations = [
      open_operation(%{"operation_id" => "stay", "departure_on" => "2026-12-10"}),
      open_operation(%{"operation_id" => "rooms", "rooms" => []}),
      open_operation(%{"operation_id" => "rate", "rate_plan" => "mystery"}),
      Map.delete(open_operation(%{"operation_id" => "missing"}), "guest_id"),
      open_operation(%{"operation_id" => "valid"}),
      open_operation(%{"operation_id" => "duplicate"})
    ]

    assert [
             %{"code" => "invalid_stay"},
             %{"code" => "invalid_rooms"},
             %{"code" => "invalid_rate_plan"},
             %{"code" => "invalid_operation"},
             %{"status" => "applied"},
             %{"code" => "group_already_exists"}
           ] = post_operations(conn, operations)
  end

  test "processes payments in order and enforces revision before domain validation", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "expected_revision" => 1,
        "amount_cents" => 5_000
      },
      %{
        "operation_id" => "stale",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "expected_revision" => 1,
        "amount_cents" => -1
      },
      %{
        "operation_id" => "too-much",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 20_000
      }
    ]

    assert [_, paid, stale, exceeds] = post_operations(conn, operations)
    assert paid["outstanding_deposit_cents"] == 14_500
    assert paid["revision"] == 2

    assert stale == %{
             "operation_id" => "stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert exceeds["code"] == "payment_exceeds_outstanding"

    data = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert data["deposit_paid_cents"] == 5_000
    assert data["revision"] == 2

    ledger = conn |> get(~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

    assert ledger == %{
             "cash_converted_to_credit_cents" => 0,
             "cash_held_cents" => 5_000,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "reschedules by preserving stay length and rejects unusable dates", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        "operation_id" => "move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2027-01-02"
      },
      %{
        "operation_id" => "bad-move",
        "type" => "reschedule_group",
        "occurred_on" => "2027-02-01",
        "group_id" => "group-81",
        "new_arrival_on" => "2027-02-01"
      }
    ]

    assert [_, moved, bad] = post_operations(conn, operations)
    assert moved["new_arrival_on"] == "2027-01-02"
    assert moved["new_departure_on"] == "2027-01-05"
    assert moved["revision"] == 2
    assert bad["code"] == "invalid_stay"
  end

  test "cancellation refunds flexible cash at least fourteen days before arrival", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 6_000
      },
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      },
      %{
        "operation_id" => "after",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-27",
        "group_id" => "group-81",
        "amount_cents" => 1
      }
    ]

    assert [_, _, cancelled, after_cancel] = post_operations(conn, operations)
    assert cancelled["refunded_cents"] == 6_000
    assert cancelled["retained_cents"] == 0
    assert cancelled["revision"] == 3
    assert after_cancel["code"] == "group_not_active"

    group = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert group["status"] == "cancelled"
    assert group["outstanding_deposit_cents"] == 0

    ledger = conn |> get(~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

    assert ledger == %{
             "cash_converted_to_credit_cents" => 0,
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 6_000,
             "cash_retained_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "fixes flexible policy at booking and recomputes its deadline after rescheduling", %{
    conn: conn
  } do
    newer =
      open_operation(%{
        "operation_id" => "open-new",
        "group_id" => "new-policy",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-13"
      })

    assert [_, _, moved] =
             post_operations(conn, [
               open_operation(),
               newer,
               %{
                 "operation_id" => "move",
                 "type" => "reschedule_group",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2027-04-10"
               }
             ])

    old_group =
      conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

    new_group =
      conn |> get(~p"/api/v1/groups/new-policy") |> json_response(200) |> Map.fetch!("data")

    assert old_group["policy_version"] == "flex-14"
    assert old_group["refundable_until"] == "2027-03-27"
    assert moved["policy_version"] == "flex-14"
    assert moved["refundable_until"] == "2027-03-27"
    assert new_group["policy_version"] == "flex-30"
    assert new_group["refundable_until"] == "2027-02-08"

    advance =
      open_operation(%{
        "operation_id" => "open-advance-policy",
        "group_id" => "advance-policy",
        "rate_plan" => "advance_purchase"
      })

    assert [_] = post_operations(conn, [advance])

    data =
      conn
      |> get(~p"/api/v1/groups/advance-policy")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["policy_version"] == "advance-nonrefundable"
    assert data["refundable_until"] == nil
  end

  test "converts refundable cash to bonus credit and reports expiry-aware balances", %{conn: conn} do
    assert [_, _, cancelled] =
             post_operations(conn, [
               open_operation(),
               payment("group-81", "pay", 5_005),
               cancel("group-81", "credit-cancel", "2026-11-26", "hotel_credit")
             ])

    assert cancelled["refunded_cents"] == 0
    assert cancelled["retained_cents"] == 0
    assert cancelled["credit_issued_cents"] == 5_506

    credit =
      conn
      |> get(~p"/api/v1/guests/guest-22/credit?on=2027-11-26")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit == %{
             "guest_id" => "guest-22",
             "available_cents" => 5_506,
             "lots" => [
               %{
                 "source_operation_id" => "credit-cancel",
                 "remaining_cents" => 5_506,
                 "expires_on" => "2027-11-26"
               }
             ]
           }

    expired =
      conn
      |> get(~p"/api/v1/guests/guest-22/credit?on=2027-11-27")
      |> json_response(200)
      |> Map.fetch!("data")

    assert expired["available_cents"] == 0
    assert expired["lots"] == []

    ledger =
      conn |> get(~p"/api/v1/ledger?on=2027-11-26") |> json_response(200) |> Map.fetch!("data")

    assert ledger["cash_converted_to_credit_cents"] == 5_005
    assert ledger["cash_held_cents"] == 0
    assert ledger["credit_liability_cents"] == 5_506
  end

  test "applies credit, pauses expiry, and drops expired restoration on refundable cancellation",
       %{
         conn: conn
       } do
    later_group =
      open_operation(%{
        "operation_id" => "open-later",
        "group_id" => "later",
        "occurred_on" => "2027-11-26",
        "arrival_on" => "2028-01-10",
        "departure_on" => "2028-01-13"
      })

    operations = [
      open_operation(),
      payment("group-81", "pay", 5_000),
      cancel("group-81", "issue", "2026-11-26", "hotel_credit"),
      later_group,
      credit_payment("later", "use", 5_500, "2027-11-26"),
      cancel("later", "cancel-later", "2027-11-27")
    ]

    assert [_, _, _, _, applied, cancelled] = post_operations(conn, operations)
    assert applied["outstanding_deposit_cents"] == 14_000
    assert applied["revision"] == 2
    assert cancelled["credit_issued_cents"] == 0

    group = conn |> get(~p"/api/v1/groups/later") |> json_response(200) |> Map.fetch!("data")
    assert group["cash_paid_cents"] == 0
    assert group["credit_paid_cents"] == 5_500
    assert group["deposit_paid_cents"] == 5_500

    ledger =
      conn |> get(~p"/api/v1/ledger?on=2027-11-27") |> json_response(200) |> Map.fetch!("data")

    assert ledger["credit_liability_cents"] == 0
  end

  test "restores unexpired credit on refundable cancellation and consumes it otherwise", %{
    conn: conn
  } do
    flexible =
      open_operation(%{
        "operation_id" => "open-flexible",
        "group_id" => "flexible-later",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-13"
      })

    advance =
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance-later",
        "rate_plan" => "advance_purchase"
      })

    assert [_, _, _, _, _, _, _, _, nonrefundable] =
             post_operations(conn, [
               open_operation(),
               payment("group-81", "pay", 5_000),
               cancel("group-81", "issue", "2026-11-26", "hotel_credit"),
               flexible,
               credit_payment("flexible-later", "use-flex", 2_000, "2026-12-01"),
               cancel("flexible-later", "return-flex", "2026-12-01"),
               advance,
               credit_payment("advance-later", "use-advance", 1_000, "2026-12-02"),
               cancel("advance-later", "consume-advance", "2026-12-03")
             ])

    assert nonrefundable["retained_cents"] == 0
    assert nonrefundable["credit_issued_cents"] == 0

    credit =
      conn
      |> get(~p"/api/v1/guests/guest-22/credit?on=2026-12-03")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit["available_cents"] == 4_500

    ledger =
      conn |> get(~p"/api/v1/ledger?on=2026-12-03") |> json_response(200) |> Map.fetch!("data")

    assert ledger["credit_liability_cents"] == 4_500
  end

  test "rejects unavailable credit methods and insufficient credit without revising the group", %{
    conn: conn
  } do
    assert [_, unavailable, insufficient, stale] =
             post_operations(conn, [
               open_operation(),
               cancel("group-81", "too-late", "2026-11-27", "hotel_credit"),
               credit_payment("group-81", "no-credit", 100, "2026-10-05"),
               credit_payment("group-81", "stale", 100, "2026-10-05")
               |> Map.put("expected_revision", 0)
             ])

    assert unavailable["code"] == "refund_method_not_available"
    assert insufficient["code"] == "insufficient_credit"
    assert stale["code"] == "stale_revision"
    assert stale["actual_revision"] == 1

    group = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert group["status"] == "active"
    assert group["revision"] == 1
  end

  test "does not make a credit lot available before its cancellation date", %{conn: conn} do
    later_group = open_operation(%{"operation_id" => "open-later", "group_id" => "later"})

    assert [_, _, _, _, retroactive] =
             post_operations(conn, [
               open_operation(),
               payment("group-81", "pay", 1_000),
               cancel("group-81", "issue", "2026-11-26", "hotel_credit"),
               later_group,
               credit_payment("later", "retroactive", 1_000, "2026-11-25")
             ])

    assert retroactive["code"] == "insufficient_credit"

    credit =
      conn
      |> get(~p"/api/v1/guests/guest-22/credit?on=2026-11-25")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit["available_cents"] == 0
  end

  test "late flexible and advance purchase cancellations retain paid cash", %{conn: conn} do
    advance =
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase"
      })

    operations = [
      open_operation(),
      payment("group-81", "pay-flex", 1_000),
      cancel("group-81", "cancel-flex", "2026-11-27"),
      advance,
      payment("advance", "pay-advance", 2_000),
      cancel("advance", "cancel-advance", "2026-10-10")
    ]

    assert [_, _, flex, _, _, advance_result] = post_operations(conn, operations)
    assert flex["retained_cents"] == 1_000
    assert advance_result["retained_cents"] == 2_000

    ledger = conn |> get(~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_retained_cents"] == 3_000
  end

  test "returns endpoint and operation errors in the documented shapes", %{conn: conn} do
    assert conn |> post(~p"/api/v1/partner-batches", %{}) |> json_response(422) ==
             %{"error" => %{"code" => "invalid_batch"}}

    assert conn |> get(~p"/api/v1/groups/missing") |> json_response(404) ==
             %{"error" => %{"code" => "group_not_found"}}

    invalid = %{"operation_id" => "bad", "type" => "unknown", "occurred_on" => "2026-01-01"}
    malformed_date = Map.put(payment("not-there", "date", 1), "occurred_on", 123)
    missing = Map.put(payment("not-there", "missing", -1), "expected_revision", 99)

    assert [
             %{"code" => "invalid_operation"},
             %{"code" => "invalid_operation"},
             %{"code" => "group_not_found"}
           ] = post_operations(conn, [invalid, malformed_date, missing])
  end

  test "replays an applied result without consulting or changing current state", %{conn: conn} do
    operation = open_operation()

    assert [original] = post_operations(conn, [operation])
    assert [_] = post_operations(conn, [payment("group-81", "pay-after-open", 1_000)])
    assert [replayed] = post_operations(conn, [operation])

    assert replayed == original

    group = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert group["revision"] == 2
    assert group["cash_paid_cents"] == 1_000
  end

  test "rejects conflicting payloads without replacing the original result and continues", %{
    conn: conn
  } do
    original_submission = open_operation()

    conflicting_submission =
      open_operation(%{
        "rooms" => Enum.reverse(original_submission["rooms"])
      })

    assert [original] = post_operations(conn, [original_submission])

    assert [conflict, paid] =
             post_operations(conn, [
               conflicting_submission,
               payment("group-81", "pay-after-conflict", 500)
             ])

    assert conflict == %{
             "operation_id" => "open-1",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert paid["status"] == "applied"

    assert conn |> get(~p"/api/v1/operations/open-1") |> json_response(200) == %{
             "data" => original
           }
  end

  test "remembers handled rejections even after domain state makes the payload valid", %{
    conn: conn
  } do
    premature_payment = payment("group-81", "pay-before-open", 500)

    assert [rejected, _, replayed] =
             post_operations(conn, [premature_payment, open_operation(), premature_payment])

    assert rejected == %{
             "operation_id" => "pay-before-open",
             "status" => "rejected",
             "code" => "group_not_found",
             "group_id" => "group-81"
           }

    assert replayed == rejected

    group = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert group["deposit_paid_cents"] == 0
    assert group["revision"] == 1
  end

  test "replays exact stale revision details and conflicts with a corrected revision", %{
    conn: conn
  } do
    stale = payment("group-81", "stale-once", 100) |> Map.put("expected_revision", 0)

    assert [_, original_stale, _] =
             post_operations(conn, [open_operation(), stale, payment("group-81", "pay", 100)])

    assert original_stale["actual_revision"] == 1
    assert [replayed] = post_operations(conn, [stale])
    assert replayed == original_stale

    corrected = Map.put(stale, "expected_revision", 2)
    assert [%{"code" => "operation_id_conflict"}] = post_operations(conn, [corrected])
  end

  test "stores complete submissions and results in first-commit order", %{conn: conn} do
    invalid = %{
      "operation_id" => "invalid-audit",
      "type" => "unknown",
      "occurred_on" => "2026-01-01",
      "nested" => %{"b" => 2, "a" => [1, 3]}
    }

    assert [_, invalid_result] = post_operations(conn, [open_operation(), invalid])

    records =
      GroupStay.Repo.all(
        from operation in GroupStay.Reservations.Operation,
          order_by: [asc: operation.id]
      )

    assert Enum.map(records, & &1.operation_id) == ["open-1", "invalid-audit"]
    assert Enum.map(records, & &1.operation_type) == ["open_group", "unknown"]
    assert List.last(records).submission == invalid
    assert List.last(records).result == invalid_result
  end

  test "returns stored rejected operations and the operation not-found shape", %{conn: conn} do
    invalid = %{"operation_id" => "bad-read", "type" => "unknown", "occurred_on" => "2026-01-01"}
    assert [result] = post_operations(conn, [invalid])

    assert conn |> get(~p"/api/v1/operations/bad-read") |> json_response(200) == %{
             "data" => result
           }

    assert conn |> get(~p"/api/v1/operations/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  defp payment(group_id, operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel(group_id, operation_id, occurred_on, refund_method \\ nil) do
    operation = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }

    if refund_method, do: Map.put(operation, "refund_method", refund_method), else: operation
  end

  defp credit_payment(group_id, operation_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end
end
