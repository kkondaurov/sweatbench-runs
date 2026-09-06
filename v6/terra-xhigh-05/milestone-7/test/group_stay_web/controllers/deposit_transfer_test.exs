defmodule GroupStayWeb.DepositTransferTest do
  use GroupStayWeb.ConnCase

  describe "deposit transfers" do
    test "moves cash in reverse allocation order and keeps reductions and chargebacks attached to it",
         %{conn: conn} do
      submit(conn, [
        open_group("open-source", "source", "transfer-guest", ["source-a", "source-b"]),
        open_group("open-destination", "destination", "transfer-guest", [
          "destination-a",
          "destination-b"
        ]),
        payment("source-payment-1", "source", 100),
        payment("source-payment-2", "source", 100),
        transfer("move-cash", "source", "destination", 150, 3, 1)
      ])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{"revision" => 1},
                   %{"revision" => 1},
                   %{"revision" => 2},
                   %{"revision" => 3},
                   %{
                     "status" => "applied",
                     "source_group_id" => "source",
                     "destination_group_id" => "destination",
                     "amount_cents" => 150,
                     "source_outstanding_deposit_cents" => 150,
                     "destination_outstanding_deposit_cents" => 50,
                     "source_revision" => 4,
                     "destination_revision" => 2
                   }
                 ]
               } = response
      end)

      assert %{
               "data" => %{
                 "cash_paid_cents" => 50,
                 "outstanding_deposit_cents" => 150,
                 "rooms" => [
                   %{"room_id" => "source-a", "cash_paid_cents" => 50},
                   %{"room_id" => "source-b", "cash_paid_cents" => 0}
                 ]
               }
             } = get(build_conn(), "/api/v1/groups/source") |> json_response(200)

      assert %{
               "data" => %{
                 "cash_paid_cents" => 150,
                 "outstanding_deposit_cents" => 50,
                 "rooms" => [
                   %{"room_id" => "destination-a", "cash_paid_cents" => 100},
                   %{"room_id" => "destination-b", "cash_paid_cents" => 50}
                 ]
               }
             } = get(build_conn(), "/api/v1/groups/destination") |> json_response(200)

      assert %{
               "data" => %{
                 "held_cents" => 100,
                 "held_by_group" => [
                   %{"group_id" => "destination", "amount_cents" => 50},
                   %{"group_id" => "source", "amount_cents" => 50}
                 ]
               }
             } = get(build_conn(), "/api/v1/payments/source-payment-1") |> json_response(200)

      submit(build_conn(), [transfer("move-cash", "source", "destination", 150, 3, 1)])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{
                     "status" => "applied",
                     "source_revision" => 4,
                     "destination_revision" => 2
                   }
                 ]
               } = response
      end)

      submit(build_conn(), [
        %{
          "operation_id" => "reduce-transferred-payment",
          "type" => "reduce_cash_payment",
          "payment_operation_id" => "source-payment-1",
          "amount_cents" => 50,
          "expected_revision" => 4
        }
      ])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{
                     "status" => "applied",
                     "group_id" => "source",
                     "outstanding_deposit_cents" => 150,
                     "revision" => 5
                   }
                 ]
               } = response
      end)

      assert %{
               "data" => %{
                 "revision" => 3,
                 "cash_paid_cents" => 100,
                 "rooms" => [
                   %{"room_id" => "destination-a", "cash_paid_cents" => 100},
                   %{"room_id" => "destination-b", "cash_paid_cents" => 0}
                 ]
               }
             } = get(build_conn(), "/api/v1/groups/destination") |> json_response(200)

      assert %{
               "data" => %{
                 "recorded_cents" => 100,
                 "held_cents" => 50,
                 "reduced_cents" => 50,
                 "held_by_group" => [%{"group_id" => "source", "amount_cents" => 50}]
               }
             } = get(build_conn(), "/api/v1/payments/source-payment-1") |> json_response(200)

      submit(build_conn(), [
        %{
          "operation_id" => "charge-back-transferred-payment",
          "type" => "charge_back_payment",
          "payment_operation_id" => "source-payment-2",
          "expected_revision" => 5
        }
      ])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{
                     "status" => "applied",
                     "group_id" => "source",
                     "charged_back_cents" => 100,
                     "outstanding_deposit_cents" => 150,
                     "revision" => 6
                   }
                 ]
               } = response
      end)

      assert %{
               "data" => %{
                 "revision" => 4,
                 "cash_paid_cents" => 0,
                 "outstanding_deposit_cents" => 200
               }
             } = get(build_conn(), "/api/v1/groups/destination") |> json_response(200)

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "charged_back_cents" => 100,
                 "held_by_group" => []
               }
             } = get(build_conn(), "/api/v1/payments/source-payment-2") |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 50,
                 "cash_reduced_cents" => 50,
                 "cash_charged_back_cents" => 100
               }
             } = get(build_conn(), "/api/v1/ledger") |> json_response(200)
    end

    test "checks both addressed groups before transfer rules and remembers exact retries", %{
      conn: conn
    } do
      submit(conn, [
        open_group("open-source", "source", "shared-guest", ["source-room"]),
        open_group("open-same-guest", "same-guest", "shared-guest", ["same-room"]),
        open_group("open-other-guest", "other-guest", "other-guest", ["other-room"]),
        payment("fund-source", "source", 100),
        transfer("same-group", "source", "source", 50, 2, 2),
        transfer("missing-destination", "source", "unknown", 50, 2, nil),
        transfer("stale-destination", "source", "other-guest", 50, 2, 9),
        transfer("move-all", "source", "same-guest", 100, 2, 1)
      ])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{},
                   %{},
                   %{},
                   %{},
                   %{"code" => "invalid_transfer"},
                   %{"code" => "group_not_found", "group_id" => "unknown"},
                   %{
                     "code" => "stale_revision",
                     "group_id" => "other-guest",
                     "expected_revision" => 9,
                     "actual_revision" => 1
                   },
                   %{
                     "status" => "applied",
                     "source_revision" => 3,
                     "destination_revision" => 2
                   }
                 ]
               } = response
      end)

      assert %{
               "data" => %{
                 "revision" => 3,
                 "outstanding_deposit_cents" => 100
               }
             } = get(build_conn(), "/api/v1/groups/source") |> json_response(200)

      assert %{
               "data" => %{
                 "revision" => 2,
                 "cash_paid_cents" => 100,
                 "outstanding_deposit_cents" => 0
               }
             } = get(build_conn(), "/api/v1/groups/same-guest") |> json_response(200)

      submit(build_conn(), [transfer("move-all", "source", "same-guest", 100, 2, 1)])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{
                     "status" => "applied",
                     "source_revision" => 3,
                     "destination_revision" => 2
                   }
                 ]
               } = response
      end)
    end

    test "rejects unusable amounts, unavailable funding, full destinations, and inactive groups",
         %{
           conn: conn
         } do
      submit(conn, [
        open_group("open-source", "source", "validation-guest", ["source-room"]),
        open_group("open-destination", "destination", "validation-guest", ["destination-room"]),
        payment("partially-fund-source", "source", 50),
        transfer("zero-transfer", "source", "destination", 0, nil, nil),
        transfer("too-much-source", "source", "destination", 60, nil, nil),
        payment("fully-fund-destination", "destination", 100),
        transfer("too-much-destination", "source", "destination", 1, nil, nil),
        %{
          "operation_id" => "cancel-destination",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-01",
          "group_id" => "destination"
        },
        transfer("inactive-destination", "source", "destination", 1, nil, nil)
      ])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{},
                   %{},
                   %{},
                   %{"code" => "invalid_amount"},
                   %{"code" => "transfer_exceeds_held_funding"},
                   %{},
                   %{"code" => "transfer_exceeds_outstanding"},
                   %{"status" => "applied", "revision" => 3},
                   %{
                     "code" => "group_not_active",
                     "group_id" => "destination"
                   }
                 ]
               } = response
      end)

      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 50}} =
               get(build_conn(), "/api/v1/groups/source") |> json_response(200)
    end

    test "chargebacks reclassify cash settled by a destination group", %{conn: conn} do
      submit(conn, [
        open_group("open-source", "source", "settlement-guest", ["source-room"]),
        open_group("open-destination", "destination", "settlement-guest", ["destination-room"]),
        payment("settled-payment", "source", 100),
        transfer("move-settled-cash", "source", "destination", 100, 2, 1),
        %{
          "operation_id" => "cancel-destination",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-01",
          "group_id" => "destination",
          "expected_revision" => 2
        },
        %{
          "operation_id" => "charge-back-settled-payment",
          "type" => "charge_back_payment",
          "payment_operation_id" => "settled-payment",
          "expected_revision" => 3
        }
      ])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{},
                   %{},
                   %{},
                   %{"source_revision" => 3, "destination_revision" => 2},
                   %{"refunded_cents" => 100, "revision" => 3},
                   %{
                     "status" => "applied",
                     "charged_back_cents" => 100,
                     "group_id" => "source",
                     "outstanding_deposit_cents" => 100,
                     "revision" => 4
                   }
                 ]
               } = response
      end)

      assert %{"data" => %{"revision" => 4, "status" => "cancelled"}} =
               get(build_conn(), "/api/v1/groups/destination") |> json_response(200)

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "charged_back_cents" => 100,
                 "held_by_group" => []
               }
             } = get(build_conn(), "/api/v1/payments/settled-payment") |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_charged_back_cents" => 100
               }
             } = get(build_conn(), "/api/v1/ledger") |> json_response(200)
    end

    test "transferred hotel credit remains tied to its original lot", %{conn: conn} do
      submit(conn, [
        open_group("open-credit-origin", "credit-origin", "credit-guest", ["origin-room"]),
        payment("credit-origin-payment", "credit-origin", 100),
        %{
          "operation_id" => "issue-credit",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-01",
          "group_id" => "credit-origin",
          "refund_method" => "hotel_credit"
        },
        open_group("open-credit-source", "credit-source", "credit-guest", ["source-room"]),
        open_group("open-credit-destination", "credit-destination", "credit-guest", [
          "destination-room"
        ]),
        %{
          "operation_id" => "apply-credit-source",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-02",
          "group_id" => "credit-source",
          "amount_cents" => 100,
          "expected_revision" => 1
        },
        transfer("move-credit", "credit-source", "credit-destination", 100, 2, 1),
        %{
          "operation_id" => "cancel-credit-destination",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-03",
          "group_id" => "credit-destination",
          "expected_revision" => 2
        }
      ])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{},
                   %{},
                   %{"credit_issued_cents" => 110},
                   %{},
                   %{},
                   %{"revision" => 2},
                   %{"source_revision" => 3, "destination_revision" => 2},
                   %{"credit_issued_cents" => 0, "revision" => 3}
                 ]
               } = response
      end)

      assert %{
               "data" => %{
                 "guest_id" => "credit-guest",
                 "available_cents" => 110,
                 "lots" => [
                   %{
                     "source_operation_id" => "issue-credit",
                     "remaining_cents" => 110,
                     "expires_on" => "2027-11-01"
                   }
                 ]
               }
             } =
               get(build_conn(), "/api/v1/guests/credit-guest/credit?on=2026-11-03")
               |> json_response(200)
    end
  end

  defp open_group(operation_id, group_id, guest_id, room_ids) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => Enum.map(room_ids, &%{"room_id" => &1, "nightly_rate_cents" => 500})
    }
  end

  defp payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp transfer(
         operation_id,
         source_group_id,
         destination_group_id,
         amount_cents,
         expected,
         destination_expected
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
    |> maybe_put("expected_revision", expected)
    |> maybe_put("destination_expected_revision", destination_expected)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end
end
