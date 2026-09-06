defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  defp json_post(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-#{group_id}",
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: group_id,
        guest_id: "guest-22",
        property_id: "ams-canal",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-13",
        rate_plan: "flexible",
        rooms: [
          %{room_id: "room-a", nightly_rate_cents: 15_000},
          %{room_id: "room-b", nightly_rate_cents: 17_500}
        ]
      },
      overrides
    )
  end

  test "opens and reads a group with ordered rooms and calculated totals", %{conn: conn} do
    response =
      conn
      |> json_post("/api/v1/partner-batches", %{operations: [open_operation("group-81")]})
      |> json_response(200)

    assert response["results"] == [
             %{
               "operation_id" => "open-group-81",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
           ]

    assert %{
             "group_id" => "group-81",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "status" => "active",
             "revision" => 1,
             "lodging_total_cents" => 97_500,
             "deposit_due_cents" => 19_500,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19_500,
             "rooms" => [
               %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
               %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
             ]
           } = conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
  end

  test "processes a batch in order and keeps rejected operations isolated", %{conn: conn} do
    response =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          open_operation("group-ordered"),
          %{
            operation_id: "bad-payment",
            type: "record_cash_payment",
            occurred_on: "2026-10-04",
            group_id: "group-ordered",
            amount_cents: 20_000
          },
          %{
            operation_id: "good-payment",
            type: "record_cash_payment",
            occurred_on: "2026-10-04",
            group_id: "group-ordered",
            amount_cents: 19_500,
            expected_revision: 1
          },
          %{
            operation_id: "move",
            type: "reschedule_group",
            occurred_on: "2026-10-05",
            group_id: "group-ordered",
            new_arrival_on: "2026-12-20",
            expected_revision: 2
          }
        ]
      })
      |> json_response(200)

    assert Enum.map(response["results"], & &1["status"]) == [
             "applied",
             "rejected",
             "applied",
             "applied"
           ]

    assert Enum.at(response["results"], 1)["code"] == "payment_exceeds_outstanding"
    assert Enum.at(response["results"], 2)["revision"] == 2
    assert Enum.at(response["results"], 3)["new_departure_on"] == "2026-12-23"

    group =
      conn |> get("/api/v1/groups/group-ordered") |> json_response(200) |> Map.fetch!("data")

    assert group["revision"] == 3
    assert group["deposit_paid_cents"] == 19_500
    assert group["outstanding_deposit_cents"] == 0
  end

  test "rejects stale revisions before domain validation", %{conn: conn} do
    conn
    |> json_post("/api/v1/partner-batches", %{operations: [open_operation("group-stale")]})
    |> json_response(200)

    response =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "payment-stale",
            type: "record_cash_payment",
            occurred_on: "not-a-date",
            group_id: "group-stale",
            amount_cents: -1,
            expected_revision: 0
          }
        ]
      })
      |> json_response(200)

    assert response["results"] == [
             %{
               "operation_id" => "payment-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-stale",
               "expected_revision" => 0,
               "actual_revision" => 1
             }
           ]
  end

  test "cancellation moves paid cash to the appropriate ledger bucket", %{conn: conn} do
    conn
    |> json_post("/api/v1/partner-batches", %{operations: [open_operation("group-refund")]})
    |> json_response(200)

    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        %{
          operation_id: "pay-refund",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-refund",
          amount_cents: 19_500
        },
        %{
          operation_id: "cancel-refund",
          type: "cancel_group",
          occurred_on: "2026-11-26",
          group_id: "group-refund",
          expected_revision: 2
        }
      ]
    })
    |> json_response(200)

    assert %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 19_500,
             "cash_retained_cents" => 0
           } = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

    assert %{"status" => "cancelled", "outstanding_deposit_cents" => 0} =
             conn
             |> get("/api/v1/groups/group-refund")
             |> json_response(200)
             |> Map.fetch!("data")

    inactive_response =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "pay-after-cancel",
            type: "record_cash_payment",
            occurred_on: "2026-11-27",
            group_id: "group-refund",
            amount_cents: 1
          }
        ]
      })
      |> json_response(200)

    assert hd(inactive_response["results"])["code"] == "group_not_active"
  end

  test "rounds flexible deposits per room and retains late advance-purchase cash", %{conn: conn} do
    rounded =
      open_operation("group-rounding", %{
        occurred_on: "2026-09-01",
        arrival_on: "2026-09-10",
        departure_on: "2026-09-11",
        rooms: [
          %{room_id: "small-a", nightly_rate_cents: 3},
          %{room_id: "small-b", nightly_rate_cents: 3}
        ]
      })

    advance =
      open_operation("group-advance", %{
        rate_plan: "advance_purchase",
        rooms: [%{room_id: "advance-room", nightly_rate_cents: 30_000}]
      })

    response =
      conn
      |> json_post("/api/v1/partner-batches", %{operations: [rounded, advance]})
      |> json_response(200)

    assert Enum.map(response["results"], & &1["deposit_due_cents"]) == [2, 90_000]

    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        %{
          operation_id: "pay-advance",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-advance",
          amount_cents: 90_000
        },
        %{
          operation_id: "cancel-advance",
          type: "cancel_group",
          occurred_on: "2026-12-01",
          group_id: "group-advance"
        }
      ]
    })
    |> json_response(200)

    assert %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 90_000
           } = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  test "returns the specified invalid batch and operation errors", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_batch"}} =
             conn |> json_post("/api/v1/partner-batches", %{}) |> json_response(422)

    response =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{operation_id: "unknown", type: "something_else"},
          %{operation_id: "missing-group", type: "record_cash_payment", occurred_on: "2026-01-01"}
        ]
      })
      |> json_response(200)

    assert response["results"] == [
             %{
               "operation_id" => "unknown",
               "status" => "rejected",
               "code" => "invalid_operation"
             },
             %{
               "operation_id" => "missing-group",
               "status" => "rejected",
               "code" => "invalid_operation"
             }
           ]
  end

  test "fixes the cancellation policy when a group is opened", %{conn: conn} do
    old_policy =
      open_operation("policy-old", %{
        occurred_on: "2026-12-31",
        arrival_on: "2027-02-20",
        departure_on: "2027-02-22"
      })

    new_policy =
      open_operation("policy-new", %{
        occurred_on: "2027-01-01",
        arrival_on: "2027-03-20",
        departure_on: "2027-03-22"
      })

    advance =
      open_operation("policy-advance", %{
        occurred_on: "2027-01-01",
        rate_plan: "advance_purchase"
      })

    conn
    |> json_post("/api/v1/partner-batches", %{operations: [old_policy, new_policy, advance]})
    |> json_response(200)

    assert %{
             "policy_version" => "flex-14",
             "refundable_until" => "2027-02-06"
           } =
             conn |> get("/api/v1/groups/policy-old") |> json_response(200) |> Map.fetch!("data")

    assert %{
             "policy_version" => "flex-30",
             "refundable_until" => "2027-02-18"
           } =
             conn |> get("/api/v1/groups/policy-new") |> json_response(200) |> Map.fetch!("data")

    assert %{
             "policy_version" => "advance-nonrefundable",
             "refundable_until" => nil
           } =
             conn
             |> get("/api/v1/groups/policy-advance")
             |> json_response(200)
             |> Map.fetch!("data")

    response =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "move-policy-old",
            type: "reschedule_group",
            occurred_on: "2027-01-01",
            group_id: "policy-old",
            new_arrival_on: "2027-03-20",
            expected_revision: 1
          }
        ]
      })
      |> json_response(200)

    assert hd(response["results"]) == %{
             "operation_id" => "move-policy-old",
             "status" => "applied",
             "group_id" => "policy-old",
             "new_arrival_on" => "2027-03-20",
             "new_departure_on" => "2027-03-22",
             "policy_version" => "flex-14",
             "refundable_until" => "2027-03-06",
             "revision" => 2
           }
  end

  test "issues, applies, and restores hotel credit", %{conn: conn} do
    source =
      open_operation("credit-source", %{
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21",
        rooms: [%{room_id: "source-room", nightly_rate_cents: 10_000}]
      })

    target =
      open_operation("credit-target", %{
        occurred_on: "2026-12-02",
        arrival_on: "2027-02-01",
        departure_on: "2027-02-02",
        rooms: [%{room_id: "target-room", nightly_rate_cents: 10_000}]
      })

    source_response =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          source,
          %{
            operation_id: "pay-credit-source",
            type: "record_cash_payment",
            occurred_on: "2026-10-04",
            group_id: "credit-source",
            amount_cents: 2_000
          },
          %{
            operation_id: "cancel-to-credit",
            type: "cancel_group",
            occurred_on: "2026-12-01",
            group_id: "credit-source",
            refund_method: "hotel_credit"
          }
        ]
      })
      |> json_response(200)

    assert List.last(source_response["results"]) == %{
             "operation_id" => "cancel-to-credit",
             "status" => "applied",
             "group_id" => "credit-source",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 2_200,
             "revision" => 3
           }

    assert %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 2_000,
             "credit_liability_cents" => 2_200
           } = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

    conn
    |> json_post("/api/v1/partner-batches", %{operations: [target]})
    |> json_response(200)

    apply_response =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "apply-credit",
            type: "apply_hotel_credit",
            occurred_on: "2026-12-02",
            group_id: "credit-target",
            amount_cents: 1_500,
            expected_revision: 1
          }
        ]
      })
      |> json_response(200)

    assert hd(apply_response["results"]) == %{
             "operation_id" => "apply-credit",
             "status" => "applied",
             "group_id" => "credit-target",
             "amount_cents" => 1_500,
             "outstanding_deposit_cents" => 500,
             "revision" => 2
           }

    assert %{
             "guest_id" => "guest-22",
             "available_cents" => 700,
             "lots" => [
               %{
                 "source_operation_id" => "cancel-to-credit",
                 "remaining_cents" => 700,
                 "expires_on" => "2027-12-02"
               }
             ]
           } =
             conn
             |> get("/api/v1/guests/guest-22/credit?on=2026-12-02")
             |> json_response(200)
             |> Map.fetch!("data")

    assert %{"credit_paid_cents" => 1_500, "cash_paid_cents" => 0} =
             conn
             |> get("/api/v1/groups/credit-target")
             |> json_response(200)
             |> Map.fetch!("data")

    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        %{
          operation_id: "cancel-credit-target",
          type: "cancel_group",
          occurred_on: "2027-01-01",
          group_id: "credit-target",
          expected_revision: 2
        }
      ]
    })
    |> json_response(200)

    assert %{"available_cents" => 2_200} =
             conn
             |> get("/api/v1/guests/guest-22/credit?on=2027-01-01")
             |> json_response(200)
             |> Map.fetch!("data")

    assert %{"credit_liability_cents" => 2_200} =
             conn
             |> get("/api/v1/ledger?on=2027-01-01")
             |> json_response(200)
             |> Map.fetch!("data")
  end

  test "rejects unavailable credit methods and expired credit", %{conn: conn} do
    source =
      open_operation("expired-credit-source", %{
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21",
        rooms: [%{room_id: "expired-source-room", nightly_rate_cents: 10_000}]
      })

    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        source,
        %{
          operation_id: "pay-expired-source",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "expired-credit-source",
          amount_cents: 2_000
        },
        %{
          operation_id: "cancel-expired-source",
          type: "cancel_group",
          occurred_on: "2026-12-01",
          group_id: "expired-credit-source",
          refund_method: "hotel_credit"
        }
      ]
    })
    |> json_response(200)

    nonrefundable_target =
      open_operation("nonrefundable-credit-target", %{
        arrival_on: "2026-12-10",
        departure_on: "2026-12-11",
        rooms: [%{room_id: "nonref-target-room", nightly_rate_cents: 10_000}]
      })

    expired_target =
      open_operation("expired-credit-target", %{
        occurred_on: "2027-01-01",
        arrival_on: "2027-02-20",
        departure_on: "2027-02-21",
        rooms: [%{room_id: "expired-target-room", nightly_rate_cents: 10_000}]
      })

    conn
    |> json_post("/api/v1/partner-batches", %{operations: [nonrefundable_target, expired_target]})
    |> json_response(200)

    unavailable =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "bad-credit-refund",
            type: "cancel_group",
            occurred_on: "2026-12-01",
            group_id: "nonrefundable-credit-target",
            refund_method: "hotel_credit"
          }
        ]
      })
      |> json_response(200)

    assert hd(unavailable["results"]) == %{
             "operation_id" => "bad-credit-refund",
             "status" => "rejected",
             "code" => "refund_method_not_available",
             "group_id" => "nonrefundable-credit-target"
           }

    insufficient =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "expired-credit-apply",
            type: "apply_hotel_credit",
            occurred_on: "2028-01-02",
            group_id: "expired-credit-target",
            amount_cents: 1_000,
            expected_revision: 1
          }
        ]
      })
      |> json_response(200)

    assert hd(insufficient["results"])["code"] == "insufficient_credit"

    assert %{"status" => "active", "revision" => 1} =
             conn
             |> get("/api/v1/groups/expired-credit-target")
             |> json_response(200)
             |> Map.fetch!("data")
  end
end
