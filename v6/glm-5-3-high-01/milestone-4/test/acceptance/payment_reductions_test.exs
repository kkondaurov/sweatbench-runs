defmodule GroupStay.AcceptancePaymentReductionsTest do
  @moduledoc false

  use GroupStayWeb.ConnCase

  import GroupStay.PartnerTestHelpers

  describe "reduce_cash_payment" do
    test "removes held cash in reverse fill order and reopens the outstanding deposit" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 10000}),
        payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 5000})
      ])

      assert [
               %{
                 "payment_operation_id" => "op-pay-1",
                 "group_id" => "group-1",
                 "amount_cents" => 2000,
                 "outstanding_deposit_cents" => 6500,
                 "revision" => 4
               }
             ] =
               apply_operations!(build_conn(), [
                 reduce_cash_operation(%{
                   "operation_id" => "op-reduce",
                   "payment_operation_id" => "op-pay-1",
                   "amount_cents" => 2000
                 })
               ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      # The later-filled room-b allocation was removed first, then room-a's
      # allocation was split.
      assert data["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15000,
                 "status" => "active",
                 "deposit_due_cents" => 9000,
                 "cash_paid_cents" => 8000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17500,
                 "status" => "active",
                 "deposit_due_cents" => 10500,
                 "cash_paid_cents" => 5000,
                 "credit_paid_cents" => 0
               }
             ]

      assert data["cash_paid_cents"] == 13_000
      assert data["deposit_paid_cents"] == 13_000
      assert data["outstanding_deposit_cents"] == 6500

      conn = get(build_conn(), "/api/v1/payments/op-pay-1")

      assert json_response(conn, 200)["data"] == %{
               "payment_operation_id" => "op-pay-1",
               "original_group_id" => "group-1",
               "recorded_cents" => 10_000,
               "held_cents" => 8000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 2000,
               "charged_back_cents" => 0
             }

      conn = get(build_conn(), "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["cash_reduced_cents"] == 2000
      assert json_response(conn, 200)["data"]["cash_held_cents"] == 13_000
    end

    test "successive reductions compose and a full remaining reduction is valid" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 5000})
      ])

      assert [%{"outstanding_deposit_cents" => 6000, "revision" => 3}] =
               apply_operations!(build_conn(), [
                 reduce_cash_operation(%{
                   "operation_id" => "op-reduce-1",
                   "payment_operation_id" => "op-pay",
                   "amount_cents" => 2000
                 })
               ])

      assert [%{"outstanding_deposit_cents" => 9000, "revision" => 4}] =
               apply_operations!(build_conn(), [
                 reduce_cash_operation(%{
                   "operation_id" => "op-reduce-2",
                   "payment_operation_id" => "op-pay",
                   "amount_cents" => 3000
                 })
               ])

      conn =
        submit(build_conn(), [
          reduce_cash_operation(%{
            "operation_id" => "op-reduce-3",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1
          })
        ])

      assert [%{"code" => "payment_not_reducible"}] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/payments/op-pay")
      data = json_response(conn, 200)["data"]

      assert data["held_cents"] == 0
      assert data["reduced_cents"] == 5000

      conn = get(build_conn(), "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["cash_reduced_cents"] == 5000
    end

    test "settled history never moves through a reduction" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 10000}),
        cancel_rooms_operation(%{
          "operation_id" => "op-cancel-rooms",
          "room_ids" => ["room-b"]
        })
      ])

      conn =
        submit(build_conn(), [
          reduce_cash_operation(%{
            "operation_id" => "op-reduce",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 2000
          })
        ])

      assert [%{"status" => "applied", "amount_cents" => 2000}] =
               json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/payments/op-pay")
      data = json_response(conn, 200)["data"]

      assert data["refunded_cents"] == 1000
      assert data["held_cents"] == 7000
      assert data["reduced_cents"] == 2000
    end

    test "a new payment can fund the reopened deposit" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000}),
        reduce_cash_operation(%{
          "operation_id" => "op-reduce",
          "payment_operation_id" => "op-pay-1",
          "amount_cents" => 3000
        })
      ])

      assert [%{"outstanding_deposit_cents" => 0, "revision" => 4}] =
               apply_operations!(build_conn(), [
                 payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 7000})
               ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["deposit_paid_cents"] == 9000
      assert data["cash_paid_cents"] == 9000
    end

    test "rejects an unknown payment operation" do
      conn =
        submit(build_conn(), [
          reduce_cash_operation(%{"payment_operation_id" => "op-never"})
        ])

      assert [%{"code" => "operation_not_found"}] = json_response(conn, 200)["results"]
    end

    test "rejects targets that can never accept a reduction" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 5000}),
        cancel_operation(%{"operation_id" => "op-cancel"})
      ])

      # A payment that exceeded the outstanding deposit leaves a rejected
      # durable record behind.
      conn =
        submit(build_conn(), [
          payment_operation(%{
            "operation_id" => "op-pay-rejected",
            "group_id" => "group-1",
            "amount_cents" => 999_999
          })
        ])

      assert [%{"status" => "rejected"}] = json_response(conn, 200)["results"]

      for {target, index} <-
            Enum.with_index([
              {"op-open", "a non-payment operation"},
              {"op-cancel", "a cancellation operation"},
              {"op-pay-rejected", "a rejected payment"},
              {"op-pay", "an applied payment with no held cash remaining"}
            ]) do
        conn =
          submit(build_conn(), [
            reduce_cash_operation(%{
              "operation_id" => "op-reduce-#{index}",
              "payment_operation_id" => elem(target, 0)
            })
          ])

        assert [result] = json_response(conn, 200)["results"]

        assert result["code"] == "payment_not_reducible",
               "expected payment_not_reducible for #{elem(target, 0)} (#{elem(target, 1)})"
      end
    end

    test "rejects a non-positive amount" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 5000})
      ])

      for {amount, index} <- Enum.with_index([0, -100, "5000", 500.5, nil]) do
        conn =
          submit(build_conn(), [
            reduce_cash_operation(%{
              "operation_id" => "op-reduce-#{index}",
              "payment_operation_id" => "op-pay",
              "amount_cents" => amount
            })
          ])

        assert [%{"code" => "invalid_amount"}] = json_response(conn, 200)["results"]
      end
    end

    test "rejects a reduction exceeding the payment's held cash" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000}),
        payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 3000})
      ])

      conn =
        submit(build_conn(), [
          reduce_cash_operation(%{
            "operation_id" => "op-reduce",
            "payment_operation_id" => "op-pay-1",
            "amount_cents" => 5001
          })
        ])

      assert [%{"code" => "reduction_exceeds_held_cash"}] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 3
      assert data["cash_paid_cents"] == 8000

      conn =
        submit(build_conn(), [
          reduce_cash_operation(%{
            "operation_id" => "op-reduce-2",
            "payment_operation_id" => "op-pay-1",
            "amount_cents" => 5000
          })
        ])

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]
    end

    test "requires an operation that identifies a payment" do
      conn =
        submit(build_conn(), [
          reduce_cash_operation(%{
            "operation_id" => "op-reduce-nil",
            "payment_operation_id" => nil
          })
        ])

      assert [%{"code" => "invalid_operation"}] = json_response(conn, 200)["results"]

      conn =
        submit(build_conn(), [
          reduce_cash_operation(%{
            "operation_id" => "op-reduce-num",
            "payment_operation_id" => 42
          })
        ])

      assert [%{"code" => "invalid_operation"}] = json_response(conn, 200)["results"]
    end

    test "follows the revision contract against the original payment's group" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 5000})
      ])

      conn =
        submit(build_conn(), [
          reduce_cash_operation(%{
            "operation_id" => "op-reduce-stale",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1000,
            "expected_revision" => 1
          })
        ])

      assert [
               %{
                 "code" => "stale_revision",
                 "group_id" => "group-1",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn =
        submit(build_conn(), [
          reduce_cash_operation(%{
            "operation_id" => "op-reduce-current",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1000,
            "expected_revision" => 2
          })
        ])

      assert [%{"status" => "applied", "revision" => 3}] = json_response(conn, 200)["results"]
    end

    test "retrying the original payment replays its exact result without reapplying cash" do
      apply_operations!(build_conn(), [open_group_operation(%{"operation_id" => "op-open"})])

      original =
        [payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 5000})]
        |> submit_first()

      apply_operations!(build_conn(), [
        reduce_cash_operation(%{
          "operation_id" => "op-reduce",
          "payment_operation_id" => "op-pay",
          "amount_cents" => 2000
        })
      ])

      conn = submit(build_conn(), [payment_operation(%{"amount_cents" => 5000})])

      assert json_response(conn, 200)["results"] == [original]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 3
      assert data["cash_paid_cents"] == 3000
      assert data["outstanding_deposit_cents"] == 6000
    end

    test "the reduction itself is durably idempotent" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 5000})
      ])

      original =
        [
          reduce_cash_operation(%{
            "operation_id" => "op-reduce",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1000
          })
        ]
        |> submit_first()

      conn =
        submit(build_conn(), [
          reduce_cash_operation(%{
            "operation_id" => "op-reduce",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1000
          })
        ])

      assert json_response(conn, 200)["results"] == [original]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 3
      assert data["cash_paid_cents"] == 4000

      conn = get(build_conn(), "/api/v1/payments/op-pay")
      assert json_response(conn, 200)["data"]["reduced_cents"] == 1000
    end
  end

  describe "charge_back_payment" do
    test "reverses held cash on an active group and reopens the deposit" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 10000}),
        payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 5000})
      ])

      assert [
               %{
                 "payment_operation_id" => "op-pay-1",
                 "group_id" => "group-1",
                 "charged_back_cents" => 10_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 4
               }
             ] =
               apply_operations!(build_conn(), [
                 charge_back_operation(%{
                   "operation_id" => "op-chargeback",
                   "payment_operation_id" => "op-pay-1"
                 })
               ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["status"] == "active"
      assert data["cash_paid_cents"] == 5000
      assert data["deposit_paid_cents"] == 5000
      assert data["outstanding_deposit_cents"] == 14_500

      assert [
               %{"cash_paid_cents" => 0, "status" => "active", "deposit_due_cents" => 9000},
               %{"cash_paid_cents" => 5000, "status" => "active", "deposit_due_cents" => 10_500}
             ] = data["rooms"]

      conn = get(build_conn(), "/api/v1/payments/op-pay-1")

      assert json_response(conn, 200)["data"] == %{
               "payment_operation_id" => "op-pay-1",
               "original_group_id" => "group-1",
               "recorded_cents" => 10_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 10_000
             }

      conn = get(build_conn(), "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]

      assert ledger["cash_held_cents"] == 5000
      assert ledger["cash_charged_back_cents"] == 10_000
    end

    test "reclassifies refunded cash on a cancelled group without reissuing it" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 4000}),
        cancel_operation(%{"operation_id" => "op-cancel"})
      ])

      assert [
               %{
                 "charged_back_cents" => 4000,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 4
               }
             ] =
               apply_operations!(build_conn(), [
                 charge_back_operation(%{
                   "operation_id" => "op-chargeback",
                   "payment_operation_id" => "op-pay"
                 })
               ])

      conn = get(build_conn(), "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]

      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 4000
      assert ledger["cash_held_cents"] == 0

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "cancelled"
      assert data["revision"] == 4
    end

    test "moves converted principal to charged back cash and claws back the entitlement" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "occurred_on" => "2026-12-10",
          "arrival_on" => "2026-12-24",
          "departure_on" => "2026-12-25",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 3060},
            %{"room_id" => "room-b", "nightly_rate_cents" => 3070}
          ]
        }),
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "occurred_on" => "2026-12-10",
          "amount_cents" => 612
        }),
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-12-10",
          "amount_cents" => 614
        }),
        cancel_rooms_operation(%{
          "operation_id" => "op-cancel-rooms",
          "occurred_on" => "2026-12-10",
          "room_ids" => ["room-a", "room-b"],
          "refund_method" => "hotel_credit"
        })
      ])

      # The lot is worth 1349: entitlements 673 (op-pay-1) and 676 (op-pay-2).
      assert [%{"status" => "applied", "charged_back_cents" => 612}] =
               apply_operations!(build_conn(), [
                 charge_back_operation(%{
                   "operation_id" => "op-chargeback",
                   "payment_operation_id" => "op-pay-1"
                 })
               ])

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")
      assert json_response(conn, 200)["data"]["available_cents"] == 676

      conn = get(build_conn(), "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]

      assert ledger["cash_converted_to_credit_cents"] == 614
      assert ledger["cash_charged_back_cents"] == 612
      assert ledger["credit_liability_cents"] == 676

      conn = get(build_conn(), "/api/v1/payments/op-pay-1")

      assert json_response(conn, 200)["data"] == %{
               "payment_operation_id" => "op-pay-1",
               "original_group_id" => "group-1",
               "recorded_cents" => 612,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 612
             }
    end

    test "reports a shortfall when spent credit cannot cover the clawback" do
      issue_convert_and_spend!()

      # The lot (1349) is fully applied to group-2; charging back op-pay-1
      # revokes entitlement 673 that is no longer in the lot.
      assert [%{"status" => "applied", "charged_back_cents" => 612}] =
               apply_operations!(build_conn(), [
                 charge_back_operation(%{
                   "operation_id" => "op-chargeback",
                   "payment_operation_id" => "op-pay-1"
                 })
               ])

      conn = get(build_conn(), "/api/v1/groups/group-2")
      data = json_response(conn, 200)["data"]

      assert data["status"] == "active"
      assert data["revision"] == 2
      assert data["credit_paid_cents"] == 1349

      conn = get(build_conn(), "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]

      assert ledger["credit_liability_cents"] == 1349
      assert ledger["credit_shortfall_cents"] == 673

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")
      assert json_response(conn, 200)["data"]["available_cents"] == 0
    end

    test "restored credit extinguishes the shortfall before becoming available" do
      issue_convert_and_spend!()

      apply_operations!(build_conn(), [
        charge_back_operation(%{
          "operation_id" => "op-chargeback",
          "payment_operation_id" => "op-pay-1"
        })
      ])

      # Refundable cancellation of group-2 restores 1349 to the shortfalled
      # lot: 673 absorbs the clawback, 676 becomes available again.
      assert [%{"status" => "applied"}] =
               apply_operations!(build_conn(), [
                 cancel_operation(%{
                   "group_id" => "group-2",
                   "operation_id" => "op-cancel-2",
                   "occurred_on" => "2026-12-20"
                 })
               ])

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")
      assert json_response(conn, 200)["data"]["available_cents"] == 676

      conn = get(build_conn(), "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]

      assert ledger["credit_shortfall_cents"] == 0
      assert ledger["credit_liability_cents"] == 676
    end

    test "non-refundable settlement reduces the current shortfall" do
      issue_convert_and_spend!()

      apply_operations!(build_conn(), [
        charge_back_operation(%{
          "operation_id" => "op-chargeback",
          "payment_operation_id" => "op-pay-1"
        })
      ])

      conn = get(build_conn(), "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["credit_shortfall_cents"] == 673

      assert [%{"status" => "applied"}] =
               apply_operations!(build_conn(), [
                 cancel_operation(%{
                   "group_id" => "group-2",
                   "operation_id" => "op-cancel-2",
                   "occurred_on" => "2027-01-05"
                 })
               ])

      conn = get(build_conn(), "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]

      assert ledger["credit_shortfall_cents"] == 0
      assert ledger["credit_liability_cents"] == 0

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")
      assert json_response(conn, 200)["data"]["available_cents"] == 0
    end

    test "charging back a partially reduced payment skips the reduced portion" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 5000}),
        reduce_cash_operation(%{
          "operation_id" => "op-reduce",
          "payment_operation_id" => "op-pay",
          "amount_cents" => 2000
        })
      ])

      assert [%{"charged_back_cents" => 3000}] =
               apply_operations!(build_conn(), [
                 charge_back_operation(%{
                   "operation_id" => "op-chargeback",
                   "payment_operation_id" => "op-pay"
                 })
               ])

      conn = get(build_conn(), "/api/v1/payments/op-pay")
      data = json_response(conn, 200)["data"]

      assert data["reduced_cents"] == 2000
      assert data["charged_back_cents"] == 3000
      assert data["held_cents"] == 0

      conn = get(build_conn(), "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]

      assert ledger["cash_reduced_cents"] == 2000
      assert ledger["cash_charged_back_cents"] == 3000
    end

    test "rejects unusable targets" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 5000}),
        reduce_cash_operation(%{
          "operation_id" => "op-reduce",
          "payment_operation_id" => "op-pay",
          "amount_cents" => 5000
        })
      ])

      # A payment that exceeded the outstanding deposit leaves a rejected
      # durable record behind.
      conn =
        submit(build_conn(), [
          payment_operation(%{
            "operation_id" => "op-pay-rejected",
            "group_id" => "group-1",
            "amount_cents" => 999_999
          })
        ])

      assert [%{"status" => "rejected"}] = json_response(conn, 200)["results"]

      conn =
        submit(build_conn(), [
          charge_back_operation(%{"payment_operation_id" => "op-never"})
        ])

      assert [%{"code" => "operation_not_found"}] = json_response(conn, 200)["results"]

      for {target, index} <-
            Enum.with_index([
              {"op-open", "a non-payment operation"},
              {"op-pay-rejected", "a rejected payment"},
              {"op-pay", "a fully reduced payment"}
            ]) do
        conn =
          submit(build_conn(), [
            charge_back_operation(%{
              "operation_id" => "op-chargeback-#{index}",
              "payment_operation_id" => elem(target, 0)
            })
          ])

        assert [result] = json_response(conn, 200)["results"]

        assert result["code"] == "payment_not_chargeable",
               "expected payment_not_chargeable for #{elem(target, 0)} (#{elem(target, 1)})"
      end
    end

    test "a payment can be charged back only once" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 5000})
      ])

      apply_operations!(build_conn(), [
        charge_back_operation(%{
          "operation_id" => "op-chargeback",
          "payment_operation_id" => "op-pay"
        })
      ])

      conn =
        submit(build_conn(), [
          charge_back_operation(%{
            "operation_id" => "op-chargeback-2",
            "payment_operation_id" => "op-pay"
          })
        ])

      assert [%{"code" => "payment_not_chargeable"}] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 3
    end

    test "the chargeback itself is durably idempotent" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 5000})
      ])

      original =
        [
          charge_back_operation(%{
            "operation_id" => "op-chargeback",
            "payment_operation_id" => "op-pay"
          })
        ]
        |> submit_first()

      conn =
        submit(build_conn(), [
          charge_back_operation(%{
            "operation_id" => "op-chargeback",
            "payment_operation_id" => "op-pay"
          })
        ])

      assert json_response(conn, 200)["results"] == [original]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 3
      assert data["cash_paid_cents"] == 0
    end

    test "follows the revision contract against the original payment's group" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 5000})
      ])

      conn =
        submit(build_conn(), [
          charge_back_operation(%{
            "operation_id" => "op-chargeback-stale",
            "payment_operation_id" => "op-pay",
            "expected_revision" => 1
          })
        ])

      assert [
               %{
                 "code" => "stale_revision",
                 "group_id" => "group-1",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn =
        submit(build_conn(), [
          charge_back_operation(%{
            "operation_id" => "op-chargeback-current",
            "payment_operation_id" => "op-pay",
            "expected_revision" => 2
          })
        ])

      assert [%{"status" => "applied", "revision" => 3}] = json_response(conn, 200)["results"]
    end
  end

  # Two payments convert into one 1349-cent lot, which is then fully applied
  # to a second group. Entitlements: op-pay-1 owns 673, op-pay-2 owns 676.
  defp issue_convert_and_spend! do
    apply_operations!(build_conn(), [
      open_group_operation(%{
        "group_id" => "group-1",
        "operation_id" => "op-open-1",
        "occurred_on" => "2026-12-10",
        "arrival_on" => "2026-12-24",
        "departure_on" => "2026-12-25",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 3060},
          %{"room_id" => "room-b", "nightly_rate_cents" => 3070}
        ]
      }),
      payment_operation(%{
        "group_id" => "group-1",
        "operation_id" => "op-pay-1",
        "occurred_on" => "2026-12-10",
        "amount_cents" => 612
      }),
      payment_operation(%{
        "group_id" => "group-1",
        "operation_id" => "op-pay-2",
        "occurred_on" => "2026-12-10",
        "amount_cents" => 614
      }),
      cancel_rooms_operation(%{
        "group_id" => "group-1",
        "operation_id" => "op-cancel-rooms",
        "occurred_on" => "2026-12-10",
        "room_ids" => ["room-a", "room-b"],
        "refund_method" => "hotel_credit"
      }),
      open_group_operation(%{
        "group_id" => "group-2",
        "operation_id" => "op-open-2",
        "occurred_on" => "2026-12-15",
        "arrival_on" => "2027-01-10",
        "departure_on" => "2027-01-13",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 15000}
        ]
      }),
      apply_credit_operation(%{
        "group_id" => "group-2",
        "operation_id" => "op-credit-2",
        "occurred_on" => "2026-12-16",
        "amount_cents" => 1349
      })
    ])
  end

  defp submit_first(operations) do
    conn = submit(build_conn(), operations)
    assert [result] = json_response(conn, 200)["results"]
    assert result["status"] == "applied", "expected applied, got: #{inspect(result)}"
    result
  end
end
