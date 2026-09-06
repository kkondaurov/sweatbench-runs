defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  describe "room accounting and selected cancellation" do
    test "allocates new credit and cash in operation order", %{conn: conn} do
      operations =
        credit_source_operations() ++
          [
            open_operation(),
            %{
              "operation_id" => "apply-credit",
              "type" => "apply_hotel_credit",
              "occurred_on" => "2027-01-03",
              "group_id" => "group-1",
              "amount_cents" => 50
            },
            payment_operation("pay-destination", 100)
          ]

      assert %{"results" => results} = submit(conn, operations)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{"data" => %{"rooms" => [room_a, room_b, room_c]}} =
               get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)

      assert room_a["credit_paid_cents"] == 50
      assert room_a["cash_paid_cents"] == 50
      assert room_b["credit_paid_cents"] == 0
      assert room_b["cash_paid_cents"] == 50
      assert room_c["cash_paid_cents"] == 0
    end

    test "allocates in room order and settles only selected rooms in original order", %{
      conn: conn
    } do
      operations = [
        open_operation(),
        payment_operation("pay-1", 250),
        %{
          "operation_id" => "cancel-selected",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-01",
          "group_id" => "group-1",
          "room_ids" => ["room-c", "room-a"],
          "expected_revision" => 2
        }
      ]

      assert %{"results" => [_, _, cancellation]} = submit(conn, operations)

      assert cancellation == %{
               "operation_id" => "cancel-selected",
               "status" => "applied",
               "group_id" => "group-1",
               "cancelled_room_ids" => ["room-a", "room-c"],
               "refunded_cents" => 100,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert %{
               "data" => %{
                 "status" => "active",
                 "lodging_total_cents" => 1_000,
                 "deposit_due_cents" => 200,
                 "deposit_paid_cents" => 150,
                 "outstanding_deposit_cents" => 50,
                 "rooms" => [room_a, room_b, room_c]
               }
             } = get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)

      assert room_a == %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 500,
               "status" => "cancelled",
               "lodging_total_cents" => 500,
               "deposit_due_cents" => 100,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }

      assert room_b["status"] == "active"
      assert room_b["cash_paid_cents"] == 150
      assert room_c["status"] == "cancelled"

      assert %{
               "data" => %{
                 "recorded_cents" => 250,
                 "held_cents" => 150,
                 "refunded_cents" => 100
               }
             } = get(build_conn(), "/api/v1/payments/pay-1") |> json_response(200)
    end

    test "rounds a hotel-credit bonus once across all selected rooms", %{conn: conn} do
      operations = [
        open_operation(%{
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 25},
            %{"room_id" => "room-b", "nightly_rate_cents" => 25}
          ]
        }),
        payment_operation("pay-1", 10),
        %{
          "operation_id" => "cancel-selected",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-01",
          "group_id" => "group-1",
          "room_ids" => ["room-a", "room-b"],
          "refund_method" => "hotel_credit"
        }
      ]

      assert %{"results" => [_, _, cancellation]} = submit(conn, operations)
      assert cancellation["credit_issued_cents"] == 11

      assert %{"data" => %{"status" => "cancelled", "deposit_due_cents" => 0}} =
               get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)

      assert %{"data" => %{"available_cents" => 11}} =
               get(build_conn(), "/api/v1/guests/guest-1/credit?on=2026-11-01")
               |> json_response(200)
    end

    test "restores credit from selected rooms without changing sibling allocations", %{conn: conn} do
      operations =
        credit_source_operations() ++
          [
            open_operation(%{
              "occurred_on" => "2027-01-03",
              "arrival_on" => "2027-06-01",
              "departure_on" => "2027-06-02"
            }),
            %{
              "operation_id" => "apply-credit",
              "type" => "apply_hotel_credit",
              "occurred_on" => "2027-01-03",
              "group_id" => "group-1",
              "amount_cents" => 110
            },
            %{
              "operation_id" => "cancel-room-a",
              "type" => "cancel_rooms",
              "occurred_on" => "2027-01-04",
              "group_id" => "group-1",
              "room_ids" => ["room-a"]
            }
          ]

      assert %{"results" => results} = submit(conn, operations)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{"data" => %{"deposit_paid_cents" => 10, "rooms" => [room_a, room_b, _]}} =
               get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)

      assert room_a["status"] == "cancelled"
      assert room_a["credit_paid_cents"] == 0
      assert room_b["status"] == "active"
      assert room_b["credit_paid_cents"] == 10

      assert %{"data" => %{"available_cents" => 100}} =
               get(build_conn(), "/api/v1/guests/guest-1/credit?on=2027-01-04")
               |> json_response(200)

      assert %{"data" => %{"credit_liability_cents" => 110}} =
               get(build_conn(), "/api/v1/ledger?on=2027-01-04") |> json_response(200)
    end

    test "rejects the complete selected-room operation for duplicate or inactive rooms", %{
      conn: conn
    } do
      operations = [
        open_operation(),
        %{
          "operation_id" => "duplicate-rooms",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-01",
          "group_id" => "group-1",
          "room_ids" => ["room-a", "room-a"]
        },
        %{
          "operation_id" => "cancel-a",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-01",
          "group_id" => "group-1",
          "room_ids" => ["room-a"]
        },
        %{
          "operation_id" => "cancel-a-again",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-02",
          "group_id" => "group-1",
          "room_ids" => ["room-a"]
        }
      ]

      assert %{"results" => [_, duplicate, applied, inactive]} = submit(conn, operations)
      assert duplicate["code"] == "invalid_rooms"
      assert applied["revision"] == 2
      assert inactive["code"] == "invalid_rooms"

      assert %{"data" => %{"revision" => 2, "deposit_due_cents" => 500}} =
               get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)
    end
  end

  describe "cash reductions and reconciliation" do
    test "reduces held cash in reverse fill order and preserves the payment replay", %{conn: conn} do
      payment = payment_operation("pay-1", 250)

      assert %{"results" => [_, original_payment]} = submit(conn, [open_operation(), payment])

      reduction = %{
        "operation_id" => "reduce-1",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => "pay-1",
        "amount_cents" => 175,
        "expected_revision" => 2
      }

      assert %{"results" => [result]} = submit(build_conn(), [reduction])

      assert result == %{
               "operation_id" => "reduce-1",
               "status" => "applied",
               "payment_operation_id" => "pay-1",
               "group_id" => "group-1",
               "amount_cents" => 175,
               "outstanding_deposit_cents" => 525,
               "revision" => 3
             }

      assert %{"data" => %{"rooms" => [room_a, room_b, room_c]}} =
               get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)

      assert room_a["cash_paid_cents"] == 75
      assert room_b["cash_paid_cents"] == 0
      assert room_c["cash_paid_cents"] == 0

      assert json_response(get(build_conn(), "/api/v1/payments/pay-1"), 200) == %{
               "data" => %{
                 "payment_operation_id" => "pay-1",
                 "original_group_id" => "group-1",
                 "recorded_cents" => 250,
                 "held_cents" => 75,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 175,
                 "charged_back_cents" => 0
               }
             }

      assert %{"results" => [^result]} = submit(build_conn(), [reduction])
      assert %{"results" => [^original_payment]} = submit(build_conn(), [payment])
    end

    test "uses distinct reduction errors and checks revision first", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation("pay-1", 100),
        %{
          "operation_id" => "stale-reduction",
          "type" => "reduce_cash_payment",
          "occurred_on" => "bad-date",
          "payment_operation_id" => "pay-1",
          "amount_cents" => -1,
          "expected_revision" => 1
        },
        reduction_operation("too-large", "pay-1", 101),
        reduction_operation("all", "pay-1", 100),
        reduction_operation("none-left", "pay-1", 1)
      ]

      assert %{"results" => [_, _, stale, excessive, reduced, empty]} = submit(conn, operations)
      assert stale["code"] == "stale_revision"
      assert excessive["code"] == "reduction_exceeds_held_cash"
      assert reduced["status"] == "applied"
      assert empty["code"] == "payment_not_reducible"

      assert %{"data" => %{"cash_held_cents" => 0, "cash_reduced_cents" => 100}} =
               get(build_conn(), "/api/v1/ledger") |> json_response(200)
    end

    test "distinguishes missing and non-payment reconciliation targets", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/payments/missing"), 404) == %{
               "error" => %{"code" => "operation_not_found"}
             }

      assert %{"results" => [_]} = submit(build_conn(), [open_operation()])

      assert json_response(get(build_conn(), "/api/v1/payments/open-1"), 422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end
  end

  describe "payment chargebacks" do
    test "telescopes multi-payment entitlements and revokes available credit first", %{conn: conn} do
      operations = [
        open_operation(%{
          "operation_id" => "open-source",
          "group_id" => "source",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-02"
        }),
        payment_operation("pay-first", 5) |> Map.put("group_id", "source"),
        payment_operation("pay-second", 5) |> Map.put("group_id", "source"),
        %{
          "operation_id" => "issue-credit",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "source",
          "refund_method" => "hotel_credit"
        },
        open_operation(%{
          "operation_id" => "open-destination",
          "group_id" => "destination",
          "occurred_on" => "2027-01-02",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-02"
        }),
        %{
          "operation_id" => "apply-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-03",
          "group_id" => "destination",
          "amount_cents" => 4
        },
        %{
          "operation_id" => "charge-second",
          "type" => "charge_back_payment",
          "occurred_on" => "2027-01-04",
          "payment_operation_id" => "pay-second",
          "expected_revision" => 4
        }
      ]

      assert %{"results" => results} = submit(conn, operations)
      charge_second = List.last(results)
      assert charge_second["charged_back_cents"] == 5

      assert %{"data" => %{"available_cents" => 2}} =
               get(build_conn(), "/api/v1/guests/guest-1/credit?on=2027-01-04")
               |> json_response(200)

      assert %{
               "data" => %{
                 "credit_liability_cents" => 6,
                 "credit_shortfall_cents" => 0
               }
             } = get(build_conn(), "/api/v1/ledger?on=2027-01-04") |> json_response(200)

      charge_first = %{
        "operation_id" => "charge-first",
        "type" => "charge_back_payment",
        "occurred_on" => "2027-01-05",
        "payment_operation_id" => "pay-first",
        "expected_revision" => 5
      }

      assert %{"results" => [first_result]} = submit(build_conn(), [charge_first])
      assert first_result["charged_back_cents"] == 5

      assert %{
               "data" => %{
                 "credit_liability_cents" => 4,
                 "credit_shortfall_cents" => 4
               }
             } = get(build_conn(), "/api/v1/ledger?on=2027-01-05") |> json_response(200)

      assert %{"results" => [^first_result]} = submit(build_conn(), [charge_first])
    end

    test "reclassifies held, refunded, and retained portions after a partial reduction", %{
      conn: conn
    } do
      operations = [
        open_operation(%{
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 500},
            %{"room_id" => "room-b", "nightly_rate_cents" => 500},
            %{"room_id" => "room-c", "nightly_rate_cents" => 500}
          ]
        }),
        payment_operation("pay-1", 300),
        cancel_rooms_operation("refund-a", ["room-a"], "2026-11-01"),
        cancel_rooms_operation("retain-b", ["room-b"], "2026-12-10"),
        reduction_operation("reduce-held", "pay-1", 50),
        %{
          "operation_id" => "chargeback",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-12-02",
          "payment_operation_id" => "pay-1",
          "expected_revision" => 5
        }
      ]

      assert %{"results" => results} = submit(conn, operations)
      chargeback = List.last(results)
      assert chargeback["charged_back_cents"] == 250
      assert chargeback["outstanding_deposit_cents"] == 100
      assert chargeback["revision"] == 6

      assert %{
               "data" => %{
                 "recorded_cents" => 300,
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "reduced_cents" => 50,
                 "charged_back_cents" => 250
               }
             } = get(build_conn(), "/api/v1/payments/pay-1") |> json_response(200)

      assert %{
               "data" => %{
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_reduced_cents" => 50,
                 "cash_charged_back_cents" => 250
               }
             } = get(build_conn(), "/api/v1/ledger") |> json_response(200)
    end

    test "reports and absorbs shortfall without revising the credit-funded group", %{conn: conn} do
      operations =
        credit_source_operations() ++
          [
            open_operation(%{
              "operation_id" => "open-destination",
              "group_id" => "destination",
              "arrival_on" => "2027-06-01",
              "departure_on" => "2027-06-02"
            }),
            %{
              "operation_id" => "apply-credit",
              "type" => "apply_hotel_credit",
              "occurred_on" => "2027-01-03",
              "group_id" => "destination",
              "amount_cents" => 110
            },
            %{
              "operation_id" => "chargeback",
              "type" => "charge_back_payment",
              "occurred_on" => "2027-01-04",
              "payment_operation_id" => "pay-source",
              "expected_revision" => 3
            }
          ]

      assert %{"results" => results} = submit(conn, operations)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{"data" => %{"revision" => 2, "credit_paid_cents" => 110}} =
               get(build_conn(), "/api/v1/groups/destination") |> json_response(200)

      assert %{
               "data" => %{
                 "credit_liability_cents" => 110,
                 "credit_shortfall_cents" => 110,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_charged_back_cents" => 100
               }
             } = get(build_conn(), "/api/v1/ledger?on=2027-01-04") |> json_response(200)

      cancellation = %{
        "operation_id" => "cancel-destination",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-05",
        "group_id" => "destination"
      }

      assert %{"results" => [%{"status" => "applied"}]} = submit(build_conn(), [cancellation])

      assert %{
               "data" => %{
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             } = get(build_conn(), "/api/v1/ledger?on=2027-01-05") |> json_response(200)

      assert %{"data" => %{"available_cents" => 0}} =
               get(build_conn(), "/api/v1/guests/guest-1/credit?on=2027-01-05")
               |> json_response(200)
    end
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations}) |> json_response(200)
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-20",
        "departure_on" => "2026-12-21",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 500},
          %{"room_id" => "room-b", "nightly_rate_cents" => 1_000},
          %{"room_id" => "room-c", "nightly_rate_cents" => 1_500}
        ]
      },
      overrides
    )
  end

  defp payment_operation(operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => amount
    }
  end

  defp reduction_operation(operation_id, payment_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-05",
      "payment_operation_id" => payment_id,
      "amount_cents" => amount
    }
  end

  defp cancel_rooms_operation(operation_id, room_ids, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => occurred_on,
      "group_id" => "group-1",
      "room_ids" => room_ids
    }
  end

  defp credit_source_operations do
    [
      open_operation(%{
        "operation_id" => "open-source",
        "group_id" => "source",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02"
      }),
      payment_operation("pay-source", 100) |> Map.put("group_id", "source"),
      %{
        "operation_id" => "issue-credit",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }
    ]
  end
end
