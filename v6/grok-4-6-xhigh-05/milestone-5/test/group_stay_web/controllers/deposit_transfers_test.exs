defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "transfer_deposit" do
    test "moves held funding between active groups of the same guest", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          open_group_op(%{"operation_id" => "open-92", "group_id" => "group-92"}),
          transfer_op(2500)
        ])

      assert %{
               "results" => [
                 _,
                 %{"status" => "applied", "revision" => 2},
                 %{"status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "xfer-1",
                   "status" => "applied",
                   "source_group_id" => "group-81",
                   "destination_group_id" => "group-92",
                   "amount_cents" => 2500,
                   "source_outstanding_deposit_cents" => 17_000,
                   "destination_outstanding_deposit_cents" => 17_000,
                   "source_revision" => 3,
                   "destination_revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "revision" => 3,
                 "cash_paid_cents" => 2500,
                 "outstanding_deposit_cents" => 17_000,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 2500},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-92")

      assert %{
               "data" => %{
                 "revision" => 2,
                 "cash_paid_cents" => 2500,
                 "outstanding_deposit_cents" => 17_000,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 2500},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "draws source allocations in reverse order and fills destination in room order", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "open-80", "group_id" => "group-80"}),
          payment_op(2000, "group-80"),
          cancel_op("group-80", "2026-11-26", %{
            "operation_id" => "cancel-80",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(),
          payment_op(9000),
          apply_credit_op(2000, "group-81"),
          open_group_op(%{"operation_id" => "open-92", "group_id" => "group-92"}),
          transfer_op(2500)
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))
      assert List.last(results)["amount_cents"] == 2500

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 8500,
                 "credit_paid_cents" => 0,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "cash_paid_cents" => 8500,
                     "credit_paid_cents" => 0
                   },
                   %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-92")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 500,
                 "credit_paid_cents" => 2000,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "cash_paid_cents" => 500,
                     "credit_paid_cents" => 2000
                   },
                   %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "does not change ledger totals or resume credit expiry", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "open-80", "group_id" => "group-80"}),
          payment_op(2000, "group-80"),
          cancel_op("group-80", "2026-11-26", %{
            "operation_id" => "cancel-80",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(),
          payment_op(3000),
          apply_credit_op(1100, "group-81"),
          open_group_op(%{"operation_id" => "open-92", "group_id" => "group-92"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, ~p"/api/v1/ledger")
      before = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")
      credit_before = json_response(conn, 200)["data"]

      conn = post_batch(conn, [transfer_op(1500)])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")
      assert json_response(conn, 200)["data"] == before

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")
      assert json_response(conn, 200)["data"] == credit_before
    end

    test "rejects transfers with the documented codes and order", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          open_group_op(%{
            "operation_id" => "open-92",
            "group_id" => "group-92",
            "guest_id" => "guest-99"
          }),
          open_group_op(%{"operation_id" => "open-93", "group_id" => "group-93"}),
          open_group_op(%{
            "operation_id" => "open-small",
            "group_id" => "group-small",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100}]
          }),
          transfer_op(100, %{
            "operation_id" => "missing-source",
            "source_group_id" => "no-source",
            "destination_group_id" => "group-93"
          }),
          transfer_op(100, %{
            "operation_id" => "missing-dest",
            "destination_group_id" => "no-dest"
          }),
          transfer_op(100, %{"operation_id" => "same-group", "destination_group_id" => "group-81"}),
          transfer_op(100, %{"operation_id" => "other-guest"}),
          transfer_op(0, %{
            "operation_id" => "zero",
            "destination_group_id" => "group-93"
          }),
          transfer_op(50_000, %{
            "operation_id" => "over-held",
            "destination_group_id" => "group-93"
          }),
          transfer_op(100, %{
            "operation_id" => "over-out",
            "destination_group_id" => "group-small"
          })
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 _,
                 %{
                   "operation_id" => "missing-source",
                   "status" => "rejected",
                   "code" => "group_not_found",
                   "group_id" => "no-source"
                 },
                 %{
                   "operation_id" => "missing-dest",
                   "status" => "rejected",
                   "code" => "group_not_found",
                   "group_id" => "no-dest"
                 },
                 %{
                   "operation_id" => "same-group",
                   "status" => "rejected",
                   "code" => "invalid_transfer"
                 },
                 %{
                   "operation_id" => "other-guest",
                   "status" => "rejected",
                   "code" => "invalid_transfer"
                 },
                 %{"operation_id" => "zero", "status" => "rejected", "code" => "invalid_amount"},
                 %{
                   "operation_id" => "over-held",
                   "status" => "rejected",
                   "code" => "transfer_exceeds_held_funding"
                 },
                 %{
                   "operation_id" => "over-out",
                   "status" => "rejected",
                   "code" => "transfer_exceeds_outstanding"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects an inactive group with that group's id after revisions", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26"),
          open_group_op(%{"operation_id" => "open-92", "group_id" => "group-92"}),
          transfer_op(100, %{
            "operation_id" => "inactive-source",
            "expected_revision" => 1
          }),
          transfer_op(100, %{"operation_id" => "inactive-source-ok"})
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied"},
                 _,
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 3
                 },
                 %{
                   "status" => "rejected",
                   "code" => "group_not_active",
                   "group_id" => "group-81"
                 }
               ]
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "open-94", "group_id" => "group-94"}),
          payment_op(1000, "group-94"),
          open_group_op(%{"operation_id" => "open-95", "group_id" => "group-95"}),
          cancel_op("group-95", "2026-11-26"),
          transfer_op(100, %{
            "operation_id" => "inactive-dest",
            "source_group_id" => "group-94",
            "destination_group_id" => "group-95"
          })
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{
                   "status" => "rejected",
                   "code" => "group_not_active",
                   "group_id" => "group-95"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "checks source revision then destination revision", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          open_group_op(%{"operation_id" => "open-92", "group_id" => "group-92"}),
          transfer_op(100, %{
            "operation_id" => "stale-source",
            "expected_revision" => 1,
            "destination_expected_revision" => 99
          }),
          transfer_op(100, %{
            "operation_id" => "stale-dest",
            "expected_revision" => 2,
            "destination_expected_revision" => 99
          })
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 },
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-92",
                   "expected_revision" => 99,
                   "actual_revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "replays an equivalent retry without moving funding again", %{conn: conn} do
      xfer = transfer_op(2000)

      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          open_group_op(%{"operation_id" => "open-92", "group_id" => "group-92"}),
          xfer
        ])

      original = json_response(conn, 200)["results"] |> List.last()
      assert original["status"] == "applied"

      conn = get(conn, ~p"/api/v1/groups/group-81")
      after_first = json_response(conn, 200)

      conn = post_batch(conn, [xfer])
      assert hd(json_response(conn, 200)["results"]) == original

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert json_response(conn, 200) == after_first

      conn = get(conn, ~p"/api/v1/operations/xfer-1")
      assert %{"data" => ^original} = json_response(conn, 200)
    end
  end

  describe "later settlement and corrections" do
    test "settles transferred cash under the destination policy", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(4000),
          open_group_op(%{
            "operation_id" => "open-92",
            "group_id" => "group-92",
            "occurred_on" => "2027-01-15",
            "arrival_on" => "2027-03-20",
            "departure_on" => "2027-03-23"
          }),
          transfer_op(4000),
          cancel_op("group-92", "2027-02-25", %{"operation_id" => "cancel-92"})
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 4000,
                   "credit_issued_cents" => 0
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_retained_cents" => 4000,
                 "cash_refunded_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "converts transferred cash with the destination bonus and restores transferred credit",
         %{
           conn: conn
         } do
      conn =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "open-80", "group_id" => "group-80"}),
          payment_op(1000, "group-80"),
          cancel_op("group-80", "2026-11-26", %{
            "operation_id" => "cancel-80",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(),
          payment_op(2000),
          apply_credit_op(1100, "group-81"),
          open_group_op(%{"operation_id" => "open-92", "group_id" => "group-92"}),
          transfer_op(3100),
          cancel_op("group-92", "2026-11-26", %{
            "operation_id" => "cancel-92",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{
               "results" => results
             } = json_response(conn, 200)

      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 2200
             } = List.last(results)

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{
               "data" => %{
                 "available_cents" => 3300,
                 "lots" => [
                   %{"source_operation_id" => "cancel-80", "remaining_cents" => 1100},
                   %{"source_operation_id" => "cancel-92", "remaining_cents" => 2200}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "reductions follow a payment across groups in reverse allocation order", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(10_000),
          open_group_op(%{"operation_id" => "open-92", "group_id" => "group-92"}),
          transfer_op(1500),
          %{
            "operation_id" => "reduce-span",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay-10000-group-81",
            "amount_cents" => 1200
          }
        ])

      assert %{
               "results" => [
                 _,
                 %{"revision" => 2},
                 %{"revision" => 1},
                 %{"status" => "applied", "source_revision" => 3, "destination_revision" => 2},
                 %{
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 1200,
                   "outstanding_deposit_cents" => 11_000,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "revision" => 4,
                 "cash_paid_cents" => 8500,
                 "outstanding_deposit_cents" => 11_000
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-92")

      assert %{
               "data" => %{
                 "revision" => 3,
                 "cash_paid_cents" => 300,
                 "outstanding_deposit_cents" => 19_200,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 300},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "chargebacks follow held allocations into other groups", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          open_group_op(%{"operation_id" => "open-92", "group_id" => "group-92"}),
          transfer_op(2000),
          %{
            "operation_id" => "cb-span",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay-5000-group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "group_id" => "group-81",
                   "charged_back_cents" => 5000,
                   "outstanding_deposit_cents" => 19_500,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 4, "cash_paid_cents" => 0}} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-92")
      assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 0}} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{"data" => %{"cash_held_cents" => 0, "cash_charged_back_cents" => 5000}} =
               json_response(conn, 200)
    end

    test "consumes transferred credit on non-refundable destination settlement", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "open-80", "group_id" => "group-80"}),
          payment_op(1000, "group-80"),
          cancel_op("group-80", "2026-11-26", %{
            "operation_id" => "cancel-80",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(),
          apply_credit_op(1100, "group-81"),
          open_group_op(%{
            "operation_id" => "open-92",
            "group_id" => "group-92",
            "rate_plan" => "advance_purchase"
          }),
          transfer_op(1100),
          cancel_op("group-92", "2026-11-26", %{"operation_id" => "cancel-92"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))
      assert List.last(results)["credit_issued_cents"] == 0

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")
      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")
      assert %{"data" => %{"credit_liability_cents" => 0}} = json_response(conn, 200)
    end

    test "charges back cash settled on the destination group", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(4000),
          open_group_op(%{"operation_id" => "open-92", "group_id" => "group-92"}),
          transfer_op(4000),
          cancel_op("group-92", "2026-11-26", %{"operation_id" => "cancel-92"}),
          %{
            "operation_id" => "cb-settled",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay-4000-group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{"status" => "applied", "refunded_cents" => 4000},
                 %{
                   "status" => "applied",
                   "group_id" => "group-81",
                   "charged_back_cents" => 4000,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_refunded_cents" => 0,
                 "cash_charged_back_cents" => 4000
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-92")
      assert %{"data" => %{"status" => "cancelled", "revision" => 3}} = json_response(conn, 200)
    end

    test "does not rewrite the original payment result after a transfer", %{conn: conn} do
      pay = payment_op(5000)

      conn =
        post_batch(conn, [
          open_group_op(),
          pay,
          open_group_op(%{"operation_id" => "open-92", "group_id" => "group-92"}),
          transfer_op(2000)
        ])

      original = json_response(conn, 200)["results"] |> Enum.at(1)

      conn = post_batch(conn, [pay])
      assert hd(json_response(conn, 200)["results"]) == original

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"cash_paid_cents" => 3000}} = json_response(conn, 200)
    end
  end

  describe "payment statement held_by_group" do
    test "omits the field until cash from the payment is transferred", %{conn: conn} do
      conn = post_batch(conn, [open_group_op(), payment_op(5000)])
      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/payments/op-pay-5000-group-81")
      body = json_response(conn, 200)

      assert body == %{
               "data" => %{
                 "payment_operation_id" => "op-pay-5000-group-81",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 5000,
                 "held_cents" => 5000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }

      refute Map.has_key?(body["data"], "held_by_group")
    end

    test "lists held cash by group after a transfer and empties once none remains", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          open_group_op(%{"operation_id" => "open-92", "group_id" => "group-92"}),
          transfer_op(2000)
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, ~p"/api/v1/payments/op-pay-5000-group-81")
      body = json_response(conn, 200)

      assert body["data"]["held_cents"] == 5000

      assert body["data"]["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 3000},
               %{"group_id" => "group-92", "amount_cents" => 2000}
             ]

      assert Enum.reduce(body["data"]["held_by_group"], 0, fn row, acc ->
               acc + row["amount_cents"]
             end) == body["data"]["held_cents"]

      conn =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "open-96", "group_id" => "group-96"}),
          %{
            "operation_id" => "xfer-rest",
            "type" => "transfer_deposit",
            "occurred_on" => "2026-10-07",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-96",
            "amount_cents" => 3000
          }
        ])

      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/payments/op-pay-5000-group-81")

      assert json_response(conn, 200)["data"]["held_by_group"] == [
               %{"group_id" => "group-92", "amount_cents" => 2000},
               %{"group_id" => "group-96", "amount_cents" => 3000}
             ]

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "reduce-all",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay-5000-group-81",
            "amount_cents" => 5000
          }
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/payments/op-pay-5000-group-81")
      after_reduce = json_response(conn, 200)

      assert after_reduce["data"]["held_cents"] == 0
      assert after_reduce["data"]["held_by_group"] == []
      assert after_reduce["data"]["reduced_cents"] == 5000
    end
  end

  defp open_group_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-1001",
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

  defp payment_op(amount_cents, group_id \\ "group-81") do
    %{
      "operation_id" => "op-pay-#{amount_cents}-#{group_id}",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(group_id, occurred_on, extras \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      extras
    )
  end

  defp apply_credit_op(amount_cents, group_id, occurred_on \\ "2026-10-05") do
    %{
      "operation_id" => "op-credit-#{amount_cents}-#{group_id}",
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp transfer_op(amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "xfer-1",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-06",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    post_json(conn, ~p"/api/v1/partner-batches", %{operations: operations})
  end

  defp post_json(conn, path, body) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(path, Jason.encode!(body))
  end
end
