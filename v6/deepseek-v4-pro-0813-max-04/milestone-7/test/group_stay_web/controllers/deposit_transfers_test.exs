defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.Operations

  alias GroupStay.Deposits.{CashAllocation, CreditApplication, CreditLot, Group, Room}
  alias GroupStay.Repo

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp batch_results(conn, operations),
    do: json_response(post_batch(conn, operations), 200)["results"]

  defp get_group(conn, group_id),
    do: json_response(get(conn, ~p"/api/v1/groups/#{group_id}"), 200)["data"]

  defp ledger(conn, params \\ %{}),
    do: json_response(get(conn, "/api/v1/ledger", params), 200)["data"]

  defp guest_credit(conn, guest_id, params \\ %{}),
    do: json_response(get(conn, "/api/v1/guests/#{guest_id}/credit", params), 200)["data"]

  defp statement(conn, payment_operation_id),
    do: json_response(get(conn, ~p"/api/v1/payments/#{payment_operation_id}"), 200)["data"]

  defp room_of(group, room_id), do: Enum.find(group["rooms"], &(&1["room_id"] == room_id))

  defp insert_legacy_group do
    group =
      Repo.insert!(%Group{
        group_id: "group-legacy",
        guest_id: "guest-legacy",
        property_id: "ams-canal",
        booked_on: ~D[2026-10-01],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-13],
        rate_plan: "flexible",
        status: "active",
        revision: 1
      })

    room_a =
      Repo.insert!(%Room{
        group_id: group.id,
        room_id: "room-a",
        nightly_rate_cents: 15_000,
        status: "active",
        deposit_due_cents: 9_000
      })

    room_b =
      Repo.insert!(%Room{
        group_id: group.id,
        room_id: "room-b",
        nightly_rate_cents: 17_500,
        status: "active",
        deposit_due_cents: 10_500
      })

    # One unattributed senior block: 9_000 cash first, then a 2_000 credit
    # application.
    Repo.insert!(%CashAllocation{
      group_id: group.id,
      room_id: room_a.id,
      payment_operation_id: nil,
      amount_cents: 9_000
    })

    lot =
      Repo.insert!(%CreditLot{
        guest_id: "guest-legacy",
        source_operation_id: "cancel-legacy",
        remaining_cents: 8_000,
        expires_on: ~D[2028-01-01],
        unrecovered_clawback_cents: 0
      })

    Repo.insert!(%CreditApplication{
      group_id: group.id,
      credit_lot_id: lot.id,
      room_id: room_b.id,
      amount_cents: 2_000
    })
  end

  defp open_destination(overrides \\ %{}) do
    Map.merge(
      open(%{"operation_id" => "op-open-92", "group_id" => "group-92"}),
      overrides
    )
  end

  # A flexible source group fully paid with 10_000 cash, cancelled while
  # refundable with hotel credit. Produces one guest-22 lot of 11_000 cents.
  defp issue_credit_lot(conn) do
    source =
      open(%{
        "operation_id" => "op-source",
        "group_id" => "group-source",
        "guest_id" => "guest-22",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-04"
      })

    pay =
      payment(%{
        "operation_id" => "op-pay-source",
        "group_id" => "group-source",
        "amount_cents" => 10_000
      })

    credit_cancel =
      cancel(%{
        "operation_id" => "op-cancel-source",
        "group_id" => "group-source",
        "occurred_on" => "2027-02-01",
        "refund_method" => "hotel_credit"
      })

    batch_results(conn, [source, pay, credit_cancel])
  end

  describe "moving held funding" do
    test "moves held cash in reverse allocation order and reports both revisions" do
      conn = build_conn()

      results =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(%{"amount_cents" => 12_000}),
          transfer(%{"amount_cents" => 5_000})
        ])

      assert Enum.at(results, 3) == %{
               "operation_id" => "op-transfer",
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-92",
               "amount_cents" => 5_000,
               "source_outstanding_deposit_cents" => 12_500,
               "destination_outstanding_deposit_cents" => 14_500,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      source = get_group(conn, "group-81")
      destination = get_group(conn, "group-92")

      # Reverse allocation order drains room-b (filled last) before room-a.
      assert room_of(source, "room-b")["cash_paid_cents"] == 0
      assert room_of(source, "room-a")["cash_paid_cents"] == 7_000
      assert source["outstanding_deposit_cents"] == 12_500
      assert source["revision"] == 3

      assert room_of(destination, "room-a")["cash_paid_cents"] == 5_000
      assert room_of(destination, "room-b")["cash_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 14_500
      assert destination["revision"] == 2

      # A transfer settles nothing: held cash is unchanged.
      assert ledger(conn)["cash_held_cents"] == 12_000
      assert ledger(conn)["cash_refunded_cents"] == 0
      assert ledger(conn)["cash_retained_cents"] == 0
      assert ledger(conn)["cash_converted_to_credit_cents"] == 0
    end

    test "draws from the most recent allocations regardless of funding kind" do
      conn = build_conn()

      issue_credit_lot(conn)

      results =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(%{"amount_cents" => 9_000}),
          apply_credit(%{"amount_cents" => 5_000}),
          transfer(%{"amount_cents" => 6_000})
        ])

      assert Enum.at(results, 4)["status"] == "applied"

      source = get_group(conn, "group-81")
      destination = get_group(conn, "group-92")

      # The 5_000 credit application is the most recent allocation, so it is
      # drawn first and fills the destination's room-a before the 1_000 cash.
      assert room_of(source, "room-b")["credit_paid_cents"] == 0
      assert room_of(source, "room-a")["cash_paid_cents"] == 8_000
      assert room_of(source, "room-a")["credit_paid_cents"] == 0

      assert room_of(destination, "room-a")["credit_paid_cents"] == 5_000
      assert room_of(destination, "room-a")["cash_paid_cents"] == 1_000

      # Applied credit stays applied: no bonus, no expiry change, liability
      # unchanged (11_000 lot total).
      assert ledger(conn)["credit_liability_cents"] == 11_000

      credit = guest_credit(conn, "guest-22")
      assert credit["available_cents"] == 6_000
    end

    test "fills rooms partially funded by earlier cash" do
      conn = build_conn()

      batch_results(conn, [
        open(),
        open_destination(),
        payment(%{"amount_cents" => 12_000}),
        payment(%{
          "operation_id" => "op-pay-92",
          "group_id" => "group-92",
          "amount_cents" => 4_000
        }),
        transfer(%{"amount_cents" => 5_000})
      ])

      destination = get_group(conn, "group-92")
      assert room_of(destination, "room-a")["cash_paid_cents"] == 9_000
      assert room_of(destination, "room-b")["cash_paid_cents"] == 0
    end

    test "moves the unattributed senior block like any other held funding" do
      conn = build_conn()

      insert_legacy_group()

      results =
        batch_results(conn, [
          open_destination(%{"guest_id" => "guest-legacy"}),
          transfer(%{
            "source_group_id" => "group-legacy",
            "destination_group_id" => "group-92",
            "amount_cents" => 3_000
          })
        ])

      assert Enum.at(results, 1) == %{
               "operation_id" => "op-transfer",
               "status" => "applied",
               "source_group_id" => "group-legacy",
               "destination_group_id" => "group-92",
               "amount_cents" => 3_000,
               "source_outstanding_deposit_cents" => 11_500,
               "destination_outstanding_deposit_cents" => 16_500,
               "source_revision" => 2,
               "destination_revision" => 2
             }

      source = get_group(conn, "group-legacy")
      destination = get_group(conn, "group-92")

      # The senior block allocated cash first and credit second, so the
      # credit is drawn first.
      assert room_of(source, "room-b")["credit_paid_cents"] == 0
      assert room_of(source, "room-a")["cash_paid_cents"] == 8_000

      assert room_of(destination, "room-a")["credit_paid_cents"] == 2_000
      assert room_of(destination, "room-a")["cash_paid_cents"] == 1_000
    end

    test "transfers observe earlier operations in the same batch" do
      conn = build_conn()

      results =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(),
          transfer(%{"amount_cents" => 10_000})
        ])

      assert Enum.at(results, 3)["status"] == "applied"
      assert get_group(conn, "group-92")["cash_paid_cents"] == 10_000
      assert get_group(conn, "group-81")["cash_paid_cents"] == 0
    end

    test "retries return the exact stored result without moving funding again" do
      conn = build_conn()

      move = transfer(%{"amount_cents" => 5_000})

      first =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(%{"amount_cents" => 12_000}),
          move
        ])

      assert batch_results(conn, [move]) == [Enum.at(first, 3)]

      assert get_group(conn, "group-81")["revision"] == 3
      assert get_group(conn, "group-92")["revision"] == 2
      assert get_group(conn, "group-92")["cash_paid_cents"] == 5_000
    end

    test "an applied transfer increments each group's revision exactly once" do
      conn = build_conn()

      results =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(%{"amount_cents" => 12_000}),
          transfer(%{
            "amount_cents" => 1_000,
            "expected_revision" => 2,
            "destination_expected_revision" => 1
          })
        ])

      assert Enum.at(results, 3)["status"] == "applied"
      assert get_group(conn, "group-81")["revision"] == 3
      assert get_group(conn, "group-92")["revision"] == 2
    end
  end

  describe "transfer rejections" do
    test "resolves source existence before destination existence" do
      conn = build_conn()

      missing_source =
        transfer(%{
          "operation_id" => "op-missing-source",
          "source_group_id" => "no-such-group",
          "destination_group_id" => "no-such-destination"
        })

      missing_destination =
        transfer(%{
          "operation_id" => "op-missing-destination",
          "source_group_id" => "group-81",
          "destination_group_id" => "no-such-destination"
        })

      results = batch_results(conn, [open(), missing_source, missing_destination])

      assert Enum.at(results, 1) == %{
               "operation_id" => "op-missing-source",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "no-such-group"
             }

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-missing-destination",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "no-such-destination"
             }
    end

    test "checks the source revision before the destination revision" do
      conn = build_conn()

      both_stale =
        transfer(%{
          "operation_id" => "op-stale",
          "expected_revision" => 1,
          "destination_expected_revision" => 0
        })

      results =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(),
          both_stale
        ])

      assert Enum.at(results, 3) == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    test "reports a destination revision mismatch with the destination group" do
      conn = build_conn()

      stale_destination =
        transfer(%{
          "operation_id" => "op-stale-dest",
          "expected_revision" => 2,
          "destination_expected_revision" => 2
        })

      results =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(),
          stale_destination
        ])

      assert Enum.at(results, 3) == %{
               "operation_id" => "op-stale-dest",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-92",
               "expected_revision" => 2,
               "actual_revision" => 1
             }

      # Revisions precede the transfer rules: no funding moved.
      assert get_group(conn, "group-81")["cash_paid_cents"] == 10_000
      assert get_group(conn, "group-92")["cash_paid_cents"] == 0
    end

    test "rejects transfers between the same group or different guests" do
      conn = build_conn()

      same_group =
        transfer(%{
          "operation_id" => "op-same",
          "destination_group_id" => "group-81",
          "amount_cents" => 1_000
        })

      other_guest =
        open_destination(%{
          "operation_id" => "op-open-23",
          "group_id" => "group-23",
          "guest_id" => "guest-23"
        })

      foreign =
        transfer(%{
          "operation_id" => "op-foreign",
          "destination_group_id" => "group-23",
          "amount_cents" => 1_000
        })

      results = batch_results(conn, [open(), payment(), same_group, other_guest, foreign])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-same",
               "status" => "rejected",
               "code" => "invalid_transfer"
             }

      assert Enum.at(results, 4) == %{
               "operation_id" => "op-foreign",
               "status" => "rejected",
               "code" => "invalid_transfer"
             }
    end

    test "rejects transfers involving an inactive group with that group's id" do
      conn = build_conn()

      inactive_source =
        transfer(%{
          "operation_id" => "op-from-cancelled",
          "amount_cents" => 1_000
        })

      inactive_destination =
        transfer(%{
          "operation_id" => "op-to-cancelled",
          "source_group_id" => "group-92",
          "destination_group_id" => "group-81",
          "amount_cents" => 1_000
        })

      results =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(),
          cancel(),
          inactive_source,
          inactive_destination
        ])

      assert Enum.at(results, 4) == %{
               "operation_id" => "op-from-cancelled",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-81"
             }

      assert Enum.at(results, 5) == %{
               "operation_id" => "op-to-cancelled",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-81"
             }
    end

    test "rejects non-positive amounts with invalid_amount" do
      conn = build_conn()

      zero = transfer(%{"operation_id" => "op-zero", "amount_cents" => 0})
      negative = transfer(%{"operation_id" => "op-neg", "amount_cents" => -5})

      results = batch_results(conn, [open(), open_destination(), payment(), zero, negative])

      assert Enum.at(results, 3)["code"] == "invalid_amount"
      assert Enum.at(results, 4)["code"] == "invalid_amount"
    end

    test "rejects amounts above the source's held funding" do
      conn = build_conn()

      too_much = transfer(%{"amount_cents" => 12_001})

      results =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(%{"amount_cents" => 12_000}),
          too_much
        ])

      assert Enum.at(results, 3) == %{
               "operation_id" => "op-transfer",
               "status" => "rejected",
               "code" => "transfer_exceeds_held_funding"
             }
    end

    test "checks held funding before the destination's outstanding deposit" do
      conn = build_conn()

      too_much = transfer(%{"amount_cents" => 20_000})

      results =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(%{"amount_cents" => 12_000}),
          too_much
        ])

      assert Enum.at(results, 3)["code"] == "transfer_exceeds_held_funding"
    end

    test "rejects amounts above the destination's outstanding deposit" do
      conn = build_conn()

      full_destination =
        payment(%{
          "operation_id" => "op-pay-92",
          "group_id" => "group-92",
          "amount_cents" => 19_500
        })

      over_outstanding = transfer(%{"amount_cents" => 1_000})

      results =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(%{"amount_cents" => 12_000}),
          full_destination,
          over_outstanding
        ])

      assert Enum.at(results, 4) == %{
               "operation_id" => "op-transfer",
               "status" => "rejected",
               "code" => "transfer_exceeds_outstanding"
             }
    end

    test "rejects malformed operations with invalid_operation" do
      conn = build_conn()

      missing_destination = %{
        "operation_id" => "op-bad",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-20",
        "source_group_id" => "group-81",
        "amount_cents" => 1_000
      }

      missing_amount =
        Map.delete(transfer(%{"operation_id" => "op-bad-2"}), "amount_cents")

      results = batch_results(conn, [open(), missing_destination, missing_amount])

      assert Enum.at(results, 1)["code"] == "invalid_operation"
      assert Enum.at(results, 2)["code"] == "invalid_operation"
    end

    test "a rejected transfer leaves both groups unchanged" do
      conn = build_conn()

      rejected = transfer(%{"amount_cents" => 12_001})

      results =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(%{"amount_cents" => 12_000}),
          rejected
        ])

      assert Enum.at(results, 3)["code"] == "transfer_exceeds_held_funding"

      assert get_group(conn, "group-81")["revision"] == 2
      assert get_group(conn, "group-92")["revision"] == 1
      assert get_group(conn, "group-81")["cash_paid_cents"] == 12_000
      assert get_group(conn, "group-92")["cash_paid_cents"] == 0
    end
  end

  describe "payment statement evolution" do
    test "adds held_by_group once a payment's cash has transferred" do
      conn = build_conn()

      batch_results(conn, [
        open(),
        open_destination(),
        payment(%{"amount_cents" => 12_000}),
        payment(%{
          "operation_id" => "op-pay-92",
          "group_id" => "group-92",
          "amount_cents" => 4_000
        }),
        transfer(%{"amount_cents" => 5_000})
      ])

      transferred = statement(conn, "op-pay")

      assert transferred["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 7_000},
               %{"group_id" => "group-92", "amount_cents" => 5_000}
             ]

      assert transferred["held_cents"] == 12_000
      assert transferred["recorded_cents"] == 12_000
      assert transferred["original_group_id"] == "group-81"

      assert Enum.sum(Enum.map(transferred["held_by_group"], & &1["amount_cents"])) ==
               transferred["held_cents"]

      # op-pay-92 never participated in a transfer: the earlier shape remains.
      untouched = statement(conn, "op-pay-92")

      assert untouched["held_cents"] == 4_000
      refute Map.has_key?(untouched, "held_by_group")
    end

    test "returns an empty held_by_group when no held cash remains" do
      conn = build_conn()

      batch_results(conn, [
        open(),
        open_destination(),
        payment(%{"amount_cents" => 12_000}),
        transfer(%{"amount_cents" => 12_000}),
        reduce(%{"amount_cents" => 12_000})
      ])

      assert statement(conn, "op-pay")["held_by_group"] == []
      assert statement(conn, "op-pay")["held_cents"] == 0
      assert statement(conn, "op-pay")["reduced_cents"] == 12_000
    end
  end

  describe "later settlement and corrections" do
    test "transferred credit restores to its original lot without another bonus" do
      conn = build_conn()

      issue_credit_lot(conn)

      batch_results(conn, [
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        }),
        open_destination(),
        apply_credit(%{"group_id" => "group-target", "amount_cents" => 10_000}),
        transfer(%{
          "source_group_id" => "group-target",
          "destination_group_id" => "group-92",
          "amount_cents" => 2_000
        })
      ])

      # room-b's 1_000 and then room-a's 1_000 credit moved to group-92.
      assert get_group(conn, "group-92")["credit_paid_cents"] == 2_000

      settle =
        cancel(%{
          "operation_id" => "op-cancel-92",
          "group_id" => "group-92",
          "occurred_on" => "2026-11-01"
        })

      results = batch_results(conn, [settle])

      assert Enum.at(results, 0)["refunded_cents"] == 0
      assert Enum.at(results, 0)["retained_cents"] == 0
      assert Enum.at(results, 0)["credit_issued_cents"] == 0

      # The 2_000 returns to its original lot: no new lot, no second bonus.
      credit = guest_credit(conn, "guest-22")
      assert credit["available_cents"] == 3_000

      [lot] = credit["lots"]
      assert lot["source_operation_id"] == "op-cancel-source"
      assert lot["remaining_cents"] == 3_000

      # Expiry paused while applied; unchanged after restoration.
      assert lot["expires_on"] == "2028-02-02"
    end

    test "transferred cash settles under the destination's cancellation policy" do
      conn = build_conn()

      destination =
        open_destination(%{"occurred_on" => "2027-01-05"})

      batch_results(conn, [
        open(),
        destination,
        payment(%{"amount_cents" => 12_000}),
        transfer(%{"amount_cents" => 5_000})
      ])

      # 2026-11-15 is 25 days before arrival: refundable under the source's
      # flex-14 policy but non-refundable under the destination's flex-30.
      settle =
        cancel(%{
          "operation_id" => "op-cancel-92",
          "group_id" => "group-92",
          "occurred_on" => "2026-11-15"
        })

      results = batch_results(conn, [settle])

      assert Enum.at(results, 0) == %{
               "operation_id" => "op-cancel-92",
               "status" => "applied",
               "group_id" => "group-92",
               "refunded_cents" => 0,
               "retained_cents" => 5_000,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert ledger(conn)["cash_retained_cents"] == 5_000
      assert ledger(conn)["cash_held_cents"] == 7_000
      assert statement(conn, "op-pay")["retained_cents"] == 5_000
    end

    test "converted transferred cash earns the standard credit bonus" do
      conn = build_conn()

      destination =
        open_destination(%{"occurred_on" => "2027-01-05"})

      batch_results(conn, [
        open(),
        destination,
        payment(%{"amount_cents" => 12_000}),
        transfer(%{"amount_cents" => 5_000})
      ])

      settle =
        cancel(%{
          "operation_id" => "op-cancel-92",
          "group_id" => "group-92",
          "occurred_on" => "2026-10-30",
          "refund_method" => "hotel_credit"
        })

      results = batch_results(conn, [settle])

      assert Enum.at(results, 0)["refunded_cents"] == 0
      assert Enum.at(results, 0)["retained_cents"] == 0
      assert Enum.at(results, 0)["credit_issued_cents"] == 5_500

      credit = guest_credit(conn, "guest-22")
      assert credit["available_cents"] == 5_500

      [lot] = credit["lots"]
      assert lot["source_operation_id"] == "op-cancel-92"
      assert lot["remaining_cents"] == 5_500

      assert ledger(conn)["cash_converted_to_credit_cents"] == 5_000
      assert statement(conn, "op-pay")["converted_to_credit_cents"] == 5_000
    end

    test "reductions follow allocations across groups and bump every group" do
      conn = build_conn()

      results =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(%{"amount_cents" => 12_000}),
          transfer(%{"amount_cents" => 5_000}),
          reduce(%{"amount_cents" => 7_000})
        ])

      assert Enum.at(results, 4) == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "amount_cents" => 7_000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 4
             }

      # Held rows were drained in reverse allocation order: the destination's
      # 5_000 first, then 2_000 of the source's room-a row.
      assert get_group(conn, "group-92")["cash_paid_cents"] == 0
      assert get_group(conn, "group-92")["revision"] == 3
      assert get_group(conn, "group-81")["cash_paid_cents"] == 5_000
      assert get_group(conn, "group-81")["revision"] == 4

      assert statement(conn, "op-pay")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 5_000}
             ]

      assert ledger(conn)["cash_reduced_cents"] == 7_000
      assert ledger(conn)["cash_held_cents"] == 5_000
    end

    test "chargebacks reclassify held cash across groups and bump revisions" do
      conn = build_conn()

      results =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(%{"amount_cents" => 12_000}),
          transfer(%{"amount_cents" => 5_000}),
          charge_back()
        ])

      assert Enum.at(results, 4) == %{
               "operation_id" => "op-reverse",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 12_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 4
             }

      assert get_group(conn, "group-81")["cash_paid_cents"] == 0
      assert get_group(conn, "group-81")["revision"] == 4
      assert get_group(conn, "group-92")["cash_paid_cents"] == 0
      assert get_group(conn, "group-92")["revision"] == 3

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 12_000
      assert statement(conn, "op-pay")["held_by_group"] == []
      assert statement(conn, "op-pay")["charged_back_cents"] == 12_000
    end

    test "reductions and chargebacks still guard the original payment group" do
      conn = build_conn()

      stale =
        reduce(%{
          "operation_id" => "op-stale-reduce",
          "amount_cents" => 1_000,
          "expected_revision" => 2
        })

      results =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(%{"amount_cents" => 12_000}),
          transfer(%{"amount_cents" => 5_000}),
          stale
        ])

      # The original payment group's revision is 3 after the transfer; the
      # destination revision change does not satisfy the guard.
      assert Enum.at(results, 4) == %{
               "operation_id" => "op-stale-reduce",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 2,
               "actual_revision" => 3
             }

      assert get_group(conn, "group-92")["revision"] == 2
    end

    test "a chargeback still bumps the original group when nothing is held there" do
      conn = build_conn()

      results =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(%{"amount_cents" => 12_000}),
          transfer(%{"amount_cents" => 12_000}),
          charge_back()
        ])

      assert Enum.at(results, 4) == %{
               "operation_id" => "op-reverse",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 12_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 4
             }

      # All held cash funded group-92, so the chargeback reopens its
      # outstanding; group-81 is the addressed group and still bumps once.
      assert get_group(conn, "group-81")["revision"] == 4
      assert get_group(conn, "group-81")["cash_paid_cents"] == 0
      assert get_group(conn, "group-92")["revision"] == 3
      assert get_group(conn, "group-92")["cash_paid_cents"] == 0
      assert get_group(conn, "group-92")["outstanding_deposit_cents"] == 19_500

      assert ledger(conn)["cash_charged_back_cents"] == 12_000
      assert statement(conn, "op-pay")["held_by_group"] == []
    end

    test "shortfall absorption applies to credit moved between groups" do
      conn = build_conn()

      issue_credit_lot(conn)

      batch_results(conn, [
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        }),
        open_destination(),
        apply_credit(%{"group_id" => "group-target", "amount_cents" => 4_000}),
        transfer(%{
          "source_group_id" => "group-target",
          "destination_group_id" => "group-92",
          "amount_cents" => 4_000
        }),
        charge_back(%{"payment_operation_id" => "op-pay-source"})
      ])

      # The whole 4_000 application now funds group-92, so the clawback's
      # current shortfall counts that group's applied credit.
      assert ledger(conn)["credit_shortfall_cents"] == 4_000
      assert ledger(conn)["credit_liability_cents"] == 4_000

      settle =
        cancel(%{
          "operation_id" => "op-cancel-92",
          "group_id" => "group-92",
          "occurred_on" => "2026-11-01"
        })

      batch_results(conn, [settle])

      # The restoration extinguishes the clawback instead of becoming
      # available credit again.
      assert guest_credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "never rewrites the original payment result" do
      conn = build_conn()

      first =
        batch_results(conn, [
          open(),
          open_destination(),
          payment(%{"amount_cents" => 12_000}),
          transfer(%{"amount_cents" => 5_000})
        ])

      original_payment_result = Enum.at(first, 2)

      # Replaying the original payment returns the exact original result.
      assert batch_results(conn, [payment(%{"amount_cents" => 12_000})]) ==
               [original_payment_result]

      assert original_payment_result == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 12_000,
               "outstanding_deposit_cents" => 7_500,
               "revision" => 2
             }

      # And nothing was reapplied.
      assert statement(conn, "op-pay")["held_cents"] == 12_000
    end
  end
end
