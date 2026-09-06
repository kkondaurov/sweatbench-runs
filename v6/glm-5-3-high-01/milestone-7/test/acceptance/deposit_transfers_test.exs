defmodule GroupStay.AcceptanceDepositTransfersTest do
  @moduledoc false

  use GroupStayWeb.ConnCase

  import GroupStay.PartnerTestHelpers

  describe "moving held funding" do
    test "moves funding in reverse allocation order and fills the destination in room order" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open-1",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 10000}),
        payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 5000}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2"
        })
      ])

      ledger_before = ledger()

      # The most recent allocation (op-pay-2's 5000 on room-b) is drawn from
      # first, so only 4000 of it moves and the rest stays behind.
      assert [
               %{
                 "source_group_id" => "group-1",
                 "destination_group_id" => "group-2",
                 "amount_cents" => 4000,
                 "source_outstanding_deposit_cents" => 8500,
                 "destination_outstanding_deposit_cents" => 5000,
                 "source_revision" => 4,
                 "destination_revision" => 2
               }
             ] =
               apply_operations!(build_conn(), [
                 transfer_deposit_operation(%{"amount_cents" => 4000})
               ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["revision"] == 4
      assert data["cash_paid_cents"] == 11_000
      assert data["deposit_paid_cents"] == 11_000
      assert data["outstanding_deposit_cents"] == 8500

      assert [
               %{"cash_paid_cents" => 9000, "credit_paid_cents" => 0},
               %{"cash_paid_cents" => 2000, "credit_paid_cents" => 0}
             ] = data["rooms"]

      conn = get(build_conn(), "/api/v1/groups/group-2")
      data = json_response(conn, 200)["data"]

      assert data["revision"] == 2
      assert data["cash_paid_cents"] == 4000
      assert data["deposit_paid_cents"] == 4000
      assert data["outstanding_deposit_cents"] == 5000
      assert [%{"cash_paid_cents" => 4000, "credit_paid_cents" => 0}] = data["rooms"]

      # A transfer settles and revalues nothing: every ledger total is
      # unchanged.
      assert ledger() == ledger_before
    end

    test "keeps provenance when mixing cash and credit and splits across rooms" do
      apply_operations!(build_conn(), [
        # A refunded cancellation issues a 2200-cent lot expiring 2027-12-10.
        open_group_operation(%{
          "operation_id" => "op-open-x",
          "group_id" => "group-x",
          "occurred_on" => "2026-12-10",
          "arrival_on" => "2026-12-24",
          "departure_on" => "2026-12-25",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
        }),
        payment_operation(%{
          "operation_id" => "op-pay-x",
          "group_id" => "group-x",
          "occurred_on" => "2026-12-10",
          "amount_cents" => 2000
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-x",
          "group_id" => "group-x",
          "occurred_on" => "2026-12-10",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation(%{
          "operation_id" => "op-open-1",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 10000}),
        apply_credit_operation(%{
          "operation_id" => "op-credit-1",
          "amount_cents" => 2200
        }),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-2",
          "amount_cents" => 5000
        })
      ])

      # Draw order: the credit allocation (latest), then op-pay-1's 1000 on
      # room-b, then 1300 split from op-pay-1's room-a allocation. The
      # destination's room-a has 4000 of capacity left, so the final cash unit
      # splits: 800 finishes room-a and 500 opens room-b.
      assert [%{"status" => "applied"}] =
               apply_operations!(build_conn(), [
                 transfer_deposit_operation(%{"amount_cents" => 4500})
               ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 7700, "credit_paid_cents" => 0},
               %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
             ] = data["rooms"]

      assert data["cash_paid_cents"] == 7700
      assert data["credit_paid_cents"] == 0
      assert data["deposit_paid_cents"] == 7700
      assert data["outstanding_deposit_cents"] == 11_800

      conn = get(build_conn(), "/api/v1/groups/group-2")
      data = json_response(conn, 200)["data"]

      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 6800, "credit_paid_cents" => 2200},
               %{"room_id" => "room-b", "cash_paid_cents" => 500, "credit_paid_cents" => 0}
             ] = data["rooms"]

      assert data["cash_paid_cents"] == 7300
      assert data["credit_paid_cents"] == 2200
      assert data["deposit_paid_cents"] == 9500
      assert data["outstanding_deposit_cents"] == 10_000

      # Cash keeps its payment identity across groups.
      conn = get(build_conn(), "/api/v1/payments/op-pay-1")
      data = json_response(conn, 200)["data"]

      assert data["held_cents"] == 10_000

      assert data["held_by_group"] == [
               %{"group_id" => "group-1", "amount_cents" => 7700},
               %{"group_id" => "group-2", "amount_cents" => 2300}
             ]

      # A payment that never participated in a transfer keeps its shape.
      conn = get(build_conn(), "/api/v1/payments/op-pay-2")
      refute Map.has_key?(json_response(conn, 200)["data"], "held_by_group")
    end

    test "transfers the complete held funding up to the destination's outstanding deposit" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open-1"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9000}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2"
        })
      ])

      assert [
               %{
                 "source_outstanding_deposit_cents" => 9000,
                 "destination_outstanding_deposit_cents" => 0,
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ] =
               apply_operations!(build_conn(), [
                 transfer_deposit_operation(%{"amount_cents" => 9000})
               ])

      conn = get(build_conn(), "/api/v1/groups/group-2")
      data = json_response(conn, 200)["data"]
      assert data["deposit_paid_cents"] == 9000
      assert data["outstanding_deposit_cents"] == 0
    end

    test "observes funding applied earlier in the same batch" do
      assert [%{"status" => "applied"}, _, _, _] =
               apply_operations!(build_conn(), [
                 open_group_operation(%{"operation_id" => "op-open-1"}),
                 open_group_operation(%{
                   "operation_id" => "op-open-2",
                   "group_id" => "group-2"
                 }),
                 payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000}),
                 transfer_deposit_operation(%{"amount_cents" => 5000})
               ])

      conn = get(build_conn(), "/api/v1/groups/group-2")
      assert json_response(conn, 200)["data"]["cash_paid_cents"] == 5000
    end
  end

  describe "transfer validation" do
    setup do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open-1"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2"
        }),
        open_group_operation(%{
          "operation_id" => "op-open-3",
          "group_id" => "group-3",
          "guest_id" => "guest-33"
        })
      ])

      :ok
    end

    test "rejects a missing source before a missing destination" do
      conn =
        submit(build_conn(), [
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer",
            "source_group_id" => "group-none",
            "destination_group_id" => "group-also-none"
          })
        ])

      assert [%{"code" => "group_not_found", "group_id" => "group-none"}] =
               json_response(conn, 200)["results"]
    end

    test "rejects a missing destination with its group_id" do
      conn =
        submit(build_conn(), [
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer",
            "destination_group_id" => "group-none"
          })
        ])

      assert [%{"code" => "group_not_found", "group_id" => "group-none"}] =
               json_response(conn, 200)["results"]
    end

    test "rejects the same group and different guests" do
      for {attrs, index} <-
            Enum.with_index([
              %{"destination_group_id" => "group-1"},
              %{"destination_group_id" => "group-3"}
            ]) do
        conn =
          submit(build_conn(), [
            transfer_deposit_operation(%{
              "operation_id" => "op-transfer-#{index}",
              "amount_cents" => 1000
            })
            |> Map.merge(attrs)
          ])

        assert [%{"code" => "invalid_transfer"}] = json_response(conn, 200)["results"]
      end

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["revision"] == 2
    end

    test "rejects an inactive source or destination with that group's id" do
      apply_operations!(build_conn(), [
        cancel_operation(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-12-01"
        })
      ])

      conn =
        submit(build_conn(), [
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-src",
            "source_group_id" => "group-2",
            "destination_group_id" => "group-1"
          })
        ])

      assert [%{"code" => "group_not_active", "group_id" => "group-2"}] =
               json_response(conn, 200)["results"]

      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open-4",
          "group_id" => "group-4"
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-4",
          "group_id" => "group-4",
          "occurred_on" => "2026-12-01"
        })
      ])

      conn =
        submit(build_conn(), [
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-dest",
            "destination_group_id" => "group-4"
          })
        ])

      assert [%{"code" => "group_not_active", "group_id" => "group-4"}] =
               json_response(conn, 200)["results"]
    end

    test "rejects a non-positive amount" do
      for {amount, index} <- Enum.with_index([0, -100, "2000", nil]) do
        conn =
          submit(build_conn(), [
            transfer_deposit_operation(%{
              "operation_id" => "op-transfer-#{index}",
              "amount_cents" => amount
            })
          ])

        assert [%{"code" => "invalid_amount"}] = json_response(conn, 200)["results"]
      end
    end

    test "rejects an amount beyond the source's held funding" do
      conn =
        submit(build_conn(), [
          transfer_deposit_operation(%{"amount_cents" => 5001})
        ])

      assert [%{"code" => "transfer_exceeds_held_funding"}] =
               json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["cash_paid_cents"] == 5000
    end

    test "rejects an amount beyond the destination's outstanding deposit" do
      # Fill the source completely and reduce the destination's outstanding
      # deposit to 8000, so 8500 is held by the source but not due anywhere.
      apply_operations!(build_conn(), [
        payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 4000}),
        payment_operation(%{
          "operation_id" => "op-pay-3",
          "group_id" => "group-2",
          "amount_cents" => 1000
        })
      ])

      conn =
        submit(build_conn(), [
          transfer_deposit_operation(%{"amount_cents" => 8500})
        ])

      assert [%{"code" => "transfer_exceeds_outstanding"}] =
               json_response(conn, 200)["results"]

      conn =
        submit(build_conn(), [
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer-2",
            "amount_cents" => 8000
          })
        ])

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]
    end

    test "requires identifiers for both groups" do
      for {attrs, index} <-
            Enum.with_index([
              %{"source_group_id" => nil},
              %{"source_group_id" => 42},
              %{"destination_group_id" => nil},
              %{"destination_group_id" => 42}
            ]) do
        conn =
          submit(build_conn(), [
            transfer_deposit_operation(%{
              "operation_id" => "op-transfer-#{index}"
            })
            |> Map.merge(attrs)
          ])

        assert [%{"code" => "invalid_operation"}] = json_response(conn, 200)["results"]
      end
    end
  end

  describe "transfer revision guards" do
    setup do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open-1"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2"
        }),
        open_group_operation(%{
          "operation_id" => "op-open-3",
          "group_id" => "group-3",
          "guest_id" => "guest-33"
        })
      ])

      :ok
    end

    test "checks the source revision before the destination revision" do
      conn =
        submit(build_conn(), [
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer",
            "expected_revision" => 1,
            "destination_expected_revision" => 5
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
    end

    test "checks the source revision before the transfer rules" do
      conn =
        submit(build_conn(), [
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer",
            "expected_revision" => 1,
            "destination_group_id" => "group-3"
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
    end

    test "checks the destination revision with the destination's identity" do
      conn =
        submit(build_conn(), [
          transfer_deposit_operation(%{
            "operation_id" => "op-transfer",
            "destination_expected_revision" => 5
          })
        ])

      assert [
               %{
                 "code" => "stale_revision",
                 "group_id" => "group-2",
                 "expected_revision" => 5,
                 "actual_revision" => 1
               }
             ] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-2")
      assert json_response(conn, 200)["data"]["revision"] == 1
    end

    test "applies when both guards match" do
      assert [
               %{
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ] =
               apply_operations!(build_conn(), [
                 transfer_deposit_operation(%{
                   "amount_cents" => 2000,
                   "expected_revision" => 2,
                   "destination_expected_revision" => 1
                 })
               ])
    end
  end

  describe "later settlement and corrections" do
    test "transferred cash settles under the destination's cancellation policy" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open-1"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
        }),
        transfer_deposit_operation(%{"amount_cents" => 5000})
      ])

      # Advance purchase is non-refundable even when the cancellation is early.
      assert [%{"retained_cents" => 5000, "refunded_cents" => 0}] =
               apply_operations!(build_conn(), [
                 cancel_operation(%{
                   "operation_id" => "op-cancel-2",
                   "group_id" => "group-2",
                   "occurred_on" => "2026-11-01"
                 })
               ])

      conn = get(build_conn(), "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_retained_cents"] == 5000
      assert ledger["cash_held_cents"] == 0

      conn = get(build_conn(), "/api/v1/payments/op-pay-1")
      data = json_response(conn, 200)["data"]

      assert data["retained_cents"] == 5000
      assert data["held_cents"] == 0
      assert data["held_by_group"] == []
    end

    test "a bonus applies when transferred cash is converted to hotel credit" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open-1"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9000}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "arrival_on" => "2026-12-24",
          "departure_on" => "2026-12-25",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
        }),
        transfer_deposit_operation(%{"amount_cents" => 2000})
      ])

      assert [%{"credit_issued_cents" => 2200, "refunded_cents" => 0}] =
               apply_operations!(build_conn(), [
                 cancel_operation(%{
                   "operation_id" => "op-cancel-2",
                   "group_id" => "group-2",
                   "occurred_on" => "2026-12-10",
                   "refund_method" => "hotel_credit"
                 })
               ])

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")
      data = json_response(conn, 200)["data"]

      assert [%{"source_operation_id" => "op-cancel-2", "remaining_cents" => 2200}] =
               data["lots"]

      conn = get(build_conn(), "/api/v1/payments/op-pay-1")
      data = json_response(conn, 200)["data"]

      assert data["converted_to_credit_cents"] == 2000
      assert data["held_cents"] == 7000
      assert data["held_by_group"] == [%{"group_id" => "group-1", "amount_cents" => 7000}]
    end

    test "transferred credit restores to its original lot and expiry without another bonus" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open-x",
          "group_id" => "group-x",
          "occurred_on" => "2026-12-10",
          "arrival_on" => "2026-12-24",
          "departure_on" => "2026-12-25",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
        }),
        payment_operation(%{
          "operation_id" => "op-pay-x",
          "group_id" => "group-x",
          "occurred_on" => "2026-12-10",
          "amount_cents" => 2000
        }),
        cancel_operation(%{
          "operation_id" => "op-cancel-x",
          "group_id" => "group-x",
          "occurred_on" => "2026-12-10",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation(%{"operation_id" => "op-open-1"}),
        apply_credit_operation(%{
          "operation_id" => "op-credit-1",
          "amount_cents" => 2200
        }),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2"
        }),
        transfer_deposit_operation(%{"amount_cents" => 2200})
      ])

      assert [%{"refunded_cents" => 0, "credit_issued_cents" => 0}] =
               apply_operations!(build_conn(), [
                 cancel_operation(%{
                   "operation_id" => "op-cancel-2",
                   "group_id" => "group-2",
                   "occurred_on" => "2026-11-20",
                   "refund_method" => "cash"
                 })
               ])

      # The restored lot keeps its original identity and expiry; no bonus is
      # granted a second time.
      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")
      data = json_response(conn, 200)["data"]

      assert [
               %{
                 "source_operation_id" => "op-cancel-x",
                 "remaining_cents" => 2200,
                 "expires_on" => "2027-12-10"
               }
             ] = data["lots"]

      conn = get(build_conn(), "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["credit_liability_cents"] == 2200
      assert ledger["cash_converted_to_credit_cents"] == 2000
    end

    test "a chargeback reclaims converted cash even when the conversion happened in another group" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open-1"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 2000}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2",
          "arrival_on" => "2026-12-24",
          "departure_on" => "2026-12-25",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
        }),
        transfer_deposit_operation(%{"amount_cents" => 2000}),
        cancel_operation(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-2",
          "occurred_on" => "2026-12-10",
          "refund_method" => "hotel_credit"
        })
      ])

      # The transferred cash became a 2200-cent lot in group-2's settlement.
      # Charging the payment back revokes that entitlement and reclassifies
      # the converted principal.
      assert [%{"charged_back_cents" => 2000, "group_id" => "group-1", "revision" => 4}] =
               apply_operations!(build_conn(), [
                 charge_back_operation(%{
                   "operation_id" => "op-chargeback",
                   "payment_operation_id" => "op-pay-1"
                 })
               ])

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")
      assert json_response(conn, 200)["data"]["available_cents"] == 0

      conn = get(build_conn(), "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]

      assert ledger["cash_converted_to_credit_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 2000
      assert ledger["credit_liability_cents"] == 0
      assert ledger["credit_shortfall_cents"] == 0

      conn = get(build_conn(), "/api/v1/payments/op-pay-1")
      data = json_response(conn, 200)["data"]

      assert data["charged_back_cents"] == 2000
      assert data["held_cents"] == 0
      assert data["held_by_group"] == []
    end

    test "a reduction removes held cash across groups in reverse allocation order" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open-1",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 10000}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2"
        }),
        transfer_deposit_operation(%{"amount_cents" => 4000})
      ])

      # op-pay-1 now holds 6000 in group-1 and 4000 in group-2. The reduction
      # removes the most recently created allocation first: all 4000 from
      # group-2, then 1000 split from group-1's room-a allocation.
      assert [
               %{
                 "payment_operation_id" => "op-pay-1",
                 "group_id" => "group-1",
                 "amount_cents" => 5000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 4
               }
             ] =
               apply_operations!(build_conn(), [
                 reduce_cash_operation(%{
                   "operation_id" => "op-reduce",
                   "payment_operation_id" => "op-pay-1",
                   "amount_cents" => 5000
                 })
               ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["revision"] == 4
      assert data["cash_paid_cents"] == 5000
      assert data["outstanding_deposit_cents"] == 14_500

      # group-2 changed too, so its revision moved even though the reduction
      # was not addressed to it.
      conn = get(build_conn(), "/api/v1/groups/group-2")
      data = json_response(conn, 200)["data"]

      assert data["revision"] == 3
      assert data["cash_paid_cents"] == 0
      assert data["deposit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 9000

      conn = get(build_conn(), "/api/v1/payments/op-pay-1")
      data = json_response(conn, 200)["data"]

      assert data["held_cents"] == 5000
      assert data["reduced_cents"] == 5000
      assert data["held_by_group"] == [%{"group_id" => "group-1", "amount_cents" => 5000}]
    end

    test "a reduction still increments the addressed group when it holds none of the cash" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open-1"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2"
        }),
        transfer_deposit_operation(%{"amount_cents" => 5000})
      ])

      assert [%{"outstanding_deposit_cents" => 9000, "revision" => 4, "group_id" => "group-1"}] =
               apply_operations!(build_conn(), [
                 reduce_cash_operation(%{
                   "operation_id" => "op-reduce",
                   "payment_operation_id" => "op-pay-1",
                   "amount_cents" => 3000
                 })
               ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["revision"] == 4
      assert data["cash_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 9000

      conn = get(build_conn(), "/api/v1/groups/group-2")
      data = json_response(conn, 200)["data"]

      assert data["revision"] == 3
      assert data["cash_paid_cents"] == 2000
    end

    test "a chargeback reclassifies held cash across groups" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open-1",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 10000}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2"
        }),
        transfer_deposit_operation(%{"amount_cents" => 4000})
      ])

      assert [
               %{
                 "payment_operation_id" => "op-pay-1",
                 "group_id" => "group-1",
                 "charged_back_cents" => 10_000,
                 "outstanding_deposit_cents" => 19_500,
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

      assert data["revision"] == 4
      assert data["cash_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 19_500

      conn = get(build_conn(), "/api/v1/groups/group-2")
      data = json_response(conn, 200)["data"]

      assert data["revision"] == 3
      assert data["cash_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 9000

      conn = get(build_conn(), "/api/v1/payments/op-pay-1")
      data = json_response(conn, 200)["data"]

      assert data["held_cents"] == 0
      assert data["charged_back_cents"] == 10_000
      assert data["held_by_group"] == []

      conn = get(build_conn(), "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]

      assert ledger["cash_charged_back_cents"] == 10_000
      assert ledger["cash_held_cents"] == 0
    end
  end

  describe "payment statement evolution" do
    test "held_by_group is ordered by group_id across several transfers" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open-1"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9000}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2"
        }),
        open_group_operation(%{
          "operation_id" => "op-open-3",
          "group_id" => "group-3"
        }),
        transfer_deposit_operation(%{
          "operation_id" => "op-transfer-2",
          "destination_group_id" => "group-2",
          "amount_cents" => 3000
        }),
        transfer_deposit_operation(%{
          "operation_id" => "op-transfer-3",
          "destination_group_id" => "group-3",
          "amount_cents" => 3000
        })
      ])

      conn = get(build_conn(), "/api/v1/payments/op-pay-1")
      data = json_response(conn, 200)["data"]

      assert data["held_cents"] == 9000

      assert data["held_by_group"] == [
               %{"group_id" => "group-1", "amount_cents" => 3000},
               %{"group_id" => "group-2", "amount_cents" => 3000},
               %{"group_id" => "group-3", "amount_cents" => 3000}
             ]
    end
  end

  describe "durability" do
    test "a retry returns the exact stored result without moving funding again" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open-1"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2"
        })
      ])

      original =
        [
          transfer_deposit_operation(%{"amount_cents" => 2000})
        ]
        |> submit_first()

      conn = submit(build_conn(), [transfer_deposit_operation(%{"amount_cents" => 2000})])
      assert json_response(conn, 200)["results"] == [original]

      conn = get(build_conn(), "/api/v1/groups/group-2")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 2
      assert data["cash_paid_cents"] == 2000

      conn = get(build_conn(), "/api/v1/operations/op-transfer")
      assert json_response(conn, 200)["data"] == original
    end

    test "reusing an identifier with a different payload conflicts" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open-1"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000}),
        open_group_operation(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-2"
        }),
        transfer_deposit_operation(%{"amount_cents" => 2000})
      ])

      conn =
        submit(build_conn(), [transfer_deposit_operation(%{"amount_cents" => 1000})])

      assert [%{"code" => "operation_id_conflict"}] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-2")
      data = json_response(conn, 200)["data"]
      assert data["cash_paid_cents"] == 2000
    end
  end

  defp ledger do
    conn = get(build_conn(), "/api/v1/ledger")
    json_response(conn, 200)["data"]
  end

  defp submit_first(operations) do
    conn = submit(build_conn(), operations)
    assert [result] = json_response(conn, 200)["results"]
    assert result["status"] == "applied", "expected applied, got: #{inspect(result)}"
    result
  end
end
