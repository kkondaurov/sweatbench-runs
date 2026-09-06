defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  import GroupStay.TestOps

  describe "moving held funding" do
    test "moves cash between active groups and reports both sides", %{conn: conn} do
      open_group!(conn)
      open_group(conn, "group-92", "guest-22", "open-92")
      json_post(conn, payment(%{"amount_cents" => 10_000}))

      conn = json_post(conn, transfer_deposit(%{"amount_cents" => 2_000}))

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-transfer",
                   "status" => "applied",
                   "source_group_id" => "group-81",
                   "destination_group_id" => "group-92",
                   "amount_cents" => 2_000,
                   "source_outstanding_deposit_cents" => 11_500,
                   "destination_outstanding_deposit_cents" => 17_500,
                   "source_revision" => 3,
                   "destination_revision" => 2
                 }
               ]
             }

      data_81 = json_response(get(conn, groups_path("group-81")), 200)["data"]
      rooms_81 = Map.new(data_81["rooms"], &{&1["room_id"], &1})
      assert rooms_81["room-a"]["cash_paid_cents"] == 8_000
      assert rooms_81["room-b"]["cash_paid_cents"] == 0
      assert data_81["outstanding_deposit_cents"] == 11_500
      assert data_81["revision"] == 3

      data_92 = json_response(get(conn, "/api/v1/groups/group-92"), 200)["data"]
      rooms_92 = Map.new(data_92["rooms"], &{&1["room_id"], &1})
      assert rooms_92["room-a"]["cash_paid_cents"] == 2_000
      assert rooms_92["room-b"]["cash_paid_cents"] == 0
      assert data_92["outstanding_deposit_cents"] == 17_500
      assert data_92["revision"] == 2

      # A transfer settles nothing: the ledger's held total is unchanged.
      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_held_cents"] == 10_000
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_retained_cents"] == 0
      assert ledger["cash_converted_to_credit_cents"] == 0
    end

    test "draws in reverse allocation order regardless of funding kind", %{conn: conn} do
      conn = issue_credit(conn, %{})
      open_group(conn, "group-x", "guest-22", "open-x")
      open_group(conn, "group-y", "guest-22", "open-y")

      # Cash first (room-a 9_000, room-b 1_000), then credit (room-b 5_000).
      json_post(
        conn,
        payment(%{"operation_id" => "pay-x", "group_id" => "group-x", "amount_cents" => 10_000})
      )

      json_post(conn, apply_credit(%{"group_id" => "group-x", "amount_cents" => 5_000}))

      # The most recently allocated funding is the 5_000 credit chunk, so a
      # 3_000 transfer draws exclusively from it.
      json_post(
        conn,
        transfer_deposit(%{
          "operation_id" => "op-move-credit",
          "source_group_id" => "group-x",
          "destination_group_id" => "group-y",
          "amount_cents" => 3_000
        })
      )

      data_y = json_response(get(conn, "/api/v1/groups/group-y"), 200)["data"]
      rooms_y = Map.new(data_y["rooms"], &{&1["room_id"], &1})
      assert rooms_y["room-a"]["cash_paid_cents"] == 0
      assert rooms_y["room-a"]["credit_paid_cents"] == 3_000

      data_x = json_response(get(conn, "/api/v1/groups/group-x"), 200)["data"]
      rooms_x = Map.new(data_x["rooms"], &{&1["room_id"], &1})
      assert rooms_x["room-a"]["cash_paid_cents"] == 9_000
      assert rooms_x["room-b"]["cash_paid_cents"] == 1_000
      assert rooms_x["room-b"]["credit_paid_cents"] == 2_000

      # Moving applied credit neither resumes its expiry nor restores it.
      credit = json_response(get(conn, guest_credit_path("guest-22")), 200)["data"]
      assert credit["available_cents"] == 6_000

      # A refundable cancellation of the destination restores the moved
      # credit to its original lot and expiry without another bonus.
      conn =
        json_post(
          conn,
          cancel(%{
            "operation_id" => "cancel-y",
            "group_id" => "group-y",
            "occurred_on" => "2026-11-26"
          })
        )

      assert [%{"status" => "applied", "credit_issued_cents" => 0}] =
               json_response(conn, 200)["results"]

      assert json_response(get(conn, guest_credit_path("guest-22")), 200) == %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 9_000,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-group-src",
                     "remaining_cents" => 9_000,
                     "expires_on" => "2027-11-27"
                   }
                 ]
               }
             }

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["credit_liability_cents"] == 11_000

      data_y = json_response(get(conn, "/api/v1/groups/group-y"), 200)["data"]
      assert data_y["status"] == "cancelled"
      assert data_y["credit_paid_cents"] == 0
    end

    test "transferred cash settles under the destination group's policy", %{conn: conn} do
      submit(
        conn,
        [
          open_group(%{
            "operation_id" => "open-adv",
            "group_id" => "group-adv",
            "guest_id" => "guest-22",
            "rate_plan" => "advance_purchase"
          })
        ]
      )

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-adv",
          "group_id" => "group-adv",
          "amount_cents" => 5_000
        })
      )

      open_group(conn, "group-flex", "guest-22", "open-flex")

      json_post(
        conn,
        transfer_deposit(%{
          "operation_id" => "op-move-cash",
          "source_group_id" => "group-adv",
          "destination_group_id" => "group-flex",
          "amount_cents" => 5_000
        })
      )

      # The destination is flexible and still in its refundable window, so
      # refundable hotel-credit settlement converts the transferred cash at
      # 110%, even though the source group was advance purchase.
      conn =
        json_post(
          conn,
          cancel(%{
            "operation_id" => "cancel-flex",
            "group_id" => "group-flex",
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          })
        )

      assert [%{"status" => "applied", "credit_issued_cents" => 5_500, "revision" => 3}] =
               json_response(conn, 200)["results"]

      assert json_response(get(conn, guest_credit_path("guest-22")), 200)["data"] ==
               %{
                 "guest_id" => "guest-22",
                 "available_cents" => 5_500,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-flex",
                     "remaining_cents" => 5_500,
                     "expires_on" => "2027-11-27"
                   }
                 ]
               }

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_converted_to_credit_cents"] == 5_000
    end
  end

  describe "rejections" do
    test "same group or different guests are invalid_transfer", %{conn: conn} do
      open_group!(conn)

      conn =
        json_post(conn, transfer_deposit(%{"destination_group_id" => "group-81"}))

      assert [
               %{
                 "operation_id" => "op-transfer",
                 "status" => "rejected",
                 "code" => "invalid_transfer"
               }
             ] = json_response(conn, 200)["results"]

      open_group(conn, "group-other-guest", "guest-other", "open-other-guest")

      conn =
        json_post(
          conn,
          transfer_deposit(%{
            "operation_id" => "op-transfer-2",
            "destination_group_id" => "group-other-guest"
          })
        )

      assert [%{"code" => "invalid_transfer"}] = json_response(conn, 200)["results"]
    end

    test "missing groups resolve source first, then destination", %{conn: conn} do
      conn =
        json_post(
          conn,
          transfer_deposit(%{
            "source_group_id" => "ghost-src",
            "destination_group_id" => "ghost-dst"
          })
        )

      assert [
               %{
                 "operation_id" => "op-transfer",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "ghost-src"
               }
             ] = json_response(conn, 200)["results"]

      open_group!(conn)

      conn =
        json_post(
          conn,
          transfer_deposit(%{
            "operation_id" => "op-transfer-2",
            "destination_group_id" => "ghost-dst"
          })
        )

      assert [
               %{
                 "operation_id" => "op-transfer-2",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "ghost-dst"
               }
             ] = json_response(conn, 200)["results"]
    end

    test "inactive groups are group_not_active with that group_id", %{conn: conn} do
      open_group!(conn)
      open_group(conn, "group-92", "guest-22", "open-92")

      json_post(
        conn,
        cancel(%{"operation_id" => "cancel-81", "group_id" => "group-81"})
      )

      conn =
        json_post(conn, transfer_deposit(%{"operation_id" => "op-t-src"}))

      assert [
               %{
                 "operation_id" => "op-t-src",
                 "status" => "rejected",
                 "code" => "group_not_active",
                 "group_id" => "group-81"
               }
             ] = json_response(conn, 200)["results"]

      # group-81 was just cancelled, so run an active source against a
      # cancelled destination.
      open_group(conn, "group-93", "guest-22", "open-93")

      json_post(
        conn,
        cancel(%{"operation_id" => "cancel-92", "group_id" => "group-92"})
      )

      conn =
        json_post(
          conn,
          transfer_deposit(%{
            "operation_id" => "op-t-dst",
            "source_group_id" => "group-93",
            "destination_group_id" => "group-92"
          })
        )

      assert [
               %{
                 "operation_id" => "op-t-dst",
                 "status" => "rejected",
                 "code" => "group_not_active",
                 "group_id" => "group-92"
               }
             ] = json_response(conn, 200)["results"]
    end

    test "amount and funding limits use the prescribed codes", %{conn: conn} do
      open_group!(conn)
      open_group(conn, "group-92", "guest-22", "open-92")

      for amount <- [0, -5, 10.5, "100"] do
        op =
          transfer_deposit(%{
            "operation_id" => "op-bad-#{inspect(amount)}",
            "amount_cents" => amount
          })

        [result] = json_response(json_post(conn, op), 200)["results"]
        assert result["code"] == "invalid_amount"
      end

      op =
        Map.delete(transfer_deposit(%{"operation_id" => "op-no-amount"}), "amount_cents")

      [result] = json_response(json_post(conn, op), 200)["results"]
      assert result["code"] == "invalid_operation"

      # The source holds less than requested.
      json_post(conn, payment(%{"amount_cents" => 1_000}))

      conn =
        json_post(
          conn,
          transfer_deposit(%{"operation_id" => "op-too-much", "amount_cents" => 2_000})
        )

      assert [%{"code" => "transfer_exceeds_held_funding"}] = json_response(conn, 200)["results"]

      # The destination needs less than requested: fund it completely first.
      json_post(
        conn,
        payment(%{"operation_id" => "pay-92", "group_id" => "group-92", "amount_cents" => 19_500})
      )

      conn =
        json_post(
          conn,
          transfer_deposit(%{"operation_id" => "op-full-dst", "amount_cents" => 1_000})
        )

      assert [%{"code" => "transfer_exceeds_outstanding"}] = json_response(conn, 200)["results"]

      # Rejections change nothing.
      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"revision" => 2, "outstanding_deposit_cents" => 18_500} = data
    end

    test "checks both revisions before the transfer rules", %{conn: conn} do
      open_group!(conn)
      open_group(conn, "group-92", "guest-22", "open-92")
      json_post(conn, payment(%{"amount_cents" => 5_000}))

      conn =
        json_post(
          conn,
          transfer_deposit(%{"operation_id" => "op-stale-src", "expected_revision" => 1})
        )

      assert [
               %{
                 "operation_id" => "op-stale-src",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn =
        json_post(
          conn,
          transfer_deposit(%{
            "operation_id" => "op-stale-dst",
            "destination_expected_revision" => 9
          })
        )

      assert [
               %{
                 "operation_id" => "op-stale-dst",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-92",
                 "expected_revision" => 9,
                 "actual_revision" => 1
               }
             ] = json_response(conn, 200)["results"]

      # Revision guards are checked before domain rules such as amount
      # validation and same-group checks.
      conn =
        json_post(
          conn,
          transfer_deposit(%{
            "operation_id" => "op-stale-same",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-81",
            "destination_expected_revision" => 9
          })
        )

      assert [
               %{
                 "operation_id" => "op-stale-same",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 9,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert data["revision"] == 2
    end

    test "guarded transfers apply when both revisions match", %{conn: conn} do
      open_group!(conn)
      open_group(conn, "group-92", "guest-22", "open-92")
      json_post(conn, payment(%{"amount_cents" => 5_000}))

      conn =
        json_post(
          conn,
          transfer_deposit(%{
            "operation_id" => "op-guarded",
            "amount_cents" => 1_000,
            "expected_revision" => 2,
            "destination_expected_revision" => 1
          })
        )

      assert [
               %{
                 "status" => "applied",
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ] = json_response(conn, 200)["results"]
    end
  end

  describe "revisions across groups" do
    test "a reduction removes held allocations in reverse order across groups and bumps both groups",
         %{
           conn: conn
         } do
      open_group!(conn)
      open_group(conn, "group-92", "guest-22", "open-92")
      json_post(conn, payment(%{"amount_cents" => 10_000}))
      json_post(conn, transfer_deposit(%{"operation_id" => "op-move", "amount_cents" => 2_000}))

      conn = json_post(conn, reduce_cash(%{"amount_cents" => 1_500}))

      assert [
               %{
                 "operation_id" => "op-reduce",
                 "status" => "applied",
                 "payment_operation_id" => "op-pay",
                 "group_id" => "group-81",
                 "amount_cents" => 1_500,
                 "outstanding_deposit_cents" => 11_500,
                 "revision" => 4
               }
             ] = json_response(conn, 200)["results"]

      # The reduction came off the group-92 chunk, the allocation created
      # last, and bumped group-92's revision although only group-81 was
      # guarded.
      data_92 = json_response(get(conn, "/api/v1/groups/group-92"), 200)["data"]
      rooms_92 = Map.new(data_92["rooms"], &{&1["room_id"], &1})
      assert rooms_92["room-a"]["cash_paid_cents"] == 500
      assert data_92["revision"] == 3

      data_81 = json_response(get(conn, groups_path("group-81")), 200)["data"]
      rooms_81 = Map.new(data_81["rooms"], &{&1["room_id"], &1})
      assert rooms_81["room-a"]["cash_paid_cents"] == 8_000
      assert data_81["revision"] == 4

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_reduced_cents"] == 1_500
      assert ledger["cash_held_cents"] == 8_500
    end

    test "a chargeback clears held cash across groups and bumps every changed group", %{
      conn: conn
    } do
      open_group!(conn)
      open_group(conn, "group-92", "guest-22", "open-92")
      json_post(conn, payment(%{"amount_cents" => 10_000}))
      json_post(conn, transfer_deposit(%{"operation_id" => "op-move", "amount_cents" => 2_000}))

      conn = json_post(conn, charge_back(%{"operation_id" => "op-cb"}))

      assert [
               %{
                 "operation_id" => "op-cb",
                 "status" => "applied",
                 "payment_operation_id" => "op-pay",
                 "group_id" => "group-81",
                 "charged_back_cents" => 10_000,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 4
               }
             ] = json_response(conn, 200)["results"]

      data_81 = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert data_81["cash_paid_cents"] == 0
      assert data_81["revision"] == 4

      data_92 = json_response(get(conn, "/api/v1/groups/group-92"), 200)["data"]
      assert data_92["cash_paid_cents"] == 0
      assert data_92["revision"] == 3

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 10_000
    end
  end

  describe "payment statement evolution" do
    test "a transferred payment reports its holding groups ordered by group_id", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))

      before = json_response(get(conn, payments_path("op-pay")), 200)["data"]
      refute Map.has_key?(before, "held_by_group")

      open_group(conn, "group-92", "guest-22", "open-92")
      json_post(conn, transfer_deposit(%{"amount_cents" => 2_000}))

      statement = json_response(get(conn, payments_path("op-pay")), 200)["data"]

      assert statement["held_cents"] == 10_000

      assert statement["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 8_000},
               %{"group_id" => "group-92", "amount_cents" => 2_000}
             ]

      amount =
        statement["held_by_group"]
        |> Enum.reduce(0, &(&1["amount_cents"] + &2))

      assert amount == statement["held_cents"]
    end

    test "groups with no held cash are omitted and an empty remainder stays empty", %{conn: conn} do
      open_group!(conn)
      open_group(conn, "group-92", "guest-22", "open-92")
      json_post(conn, payment(%{"amount_cents" => 10_000}))
      json_post(conn, transfer_deposit(%{"operation_id" => "op-move", "amount_cents" => 2_000}))

      # Remove 2_500: the group-92 allocation (2_000) drains first, leaving
      # only group-81 held cash.
      json_post(conn, reduce_cash(%{"operation_id" => "op-reduce", "amount_cents" => 2_500}))

      statement = json_response(get(conn, payments_path("op-pay")), 200)["data"]
      assert statement["held_by_group"] == [%{"group_id" => "group-81", "amount_cents" => 7_500}]

      # A chargeback empties the remaining holdings; the list stays present
      # and empty.
      json_post(conn, charge_back(%{"operation_id" => "op-cb"}))

      statement = json_response(get(conn, payments_path("op-pay")), 200)["data"]
      assert statement["held_cents"] == 0
      assert statement["held_by_group"] == []
    end
  end

  describe "durability" do
    test "transfers observe same-batch visibility and retry exactly", %{conn: conn} do
      transfer =
        transfer_deposit(%{
          "operation_id" => "op-move",
          "amount_cents" => 1_000
        })

      conn =
        submit(conn, [
          open_group(%{"operation_id" => "open-81"}),
          payment(%{"operation_id" => "pay-81", "amount_cents" => 5_000}),
          open_group(%{"operation_id" => "open-92", "group_id" => "group-92"}),
          transfer
        ])

      results = json_response(conn, 200)["results"]

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               transfer_result
             ] = results

      assert transfer_result["source_revision"] == 3
      assert transfer_result["destination_revision"] == 2

      # Retrying returns the exact stored result without moving funding again.
      assert json_response(json_post(conn, transfer), 200)["results"] == [transfer_result]

      assert [%{"code" => "operation_id_conflict"}] =
               json_response(json_post(conn, %{transfer | "amount_cents" => 2_000}), 200)[
                 "results"
               ]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert data["revision"] == 3
    end
  end

  # Opens a fresh group for a guest.
  defp open_group(conn, group_id, guest_id, operation_id) do
    submit(conn, [
      open_group(%{
        "operation_id" => operation_id,
        "group_id" => group_id,
        "guest_id" => guest_id
      })
    ])
  end

  # Opens a source group for the guest, pays it, and cancels it with hotel
  # credit so the guest owns a usable 11_000 credit lot.
  defp issue_credit(conn, overrides) do
    group_id = Map.get(overrides, :group_id, "group-src")
    guest_id = Map.get(overrides, :guest_id, "guest-22")

    conn =
      submit(conn, [
        open_group(%{
          "operation_id" => "open-#{group_id}",
          "group_id" => group_id,
          "guest_id" => guest_id
        }),
        payment(%{
          "operation_id" => "pay-#{group_id}",
          "group_id" => group_id,
          "amount_cents" => 10_000
        }),
        cancel(%{
          "operation_id" => "cancel-#{group_id}",
          "group_id" => group_id,
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        })
      ])

    [_, _, %{"status" => "applied", "credit_issued_cents" => 11_000}] =
      json_response(conn, 200)["results"]

    conn
  end
end
