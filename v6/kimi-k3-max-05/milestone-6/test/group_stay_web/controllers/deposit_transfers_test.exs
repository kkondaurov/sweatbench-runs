defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Groups.CashAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  defp post_batch(conn, body) do
    post(conn, ~p"/api/v1/partner-batches", body)
  end

  defp open_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
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

  # One flexible room for two nights at 20_000: a 8_000 deposit.
  defp open_one_room_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 20_000}]
      },
      overrides
    )
  end

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp credit_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 4_000
      },
      overrides
    )
  end

  defp transfer_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-82",
        "amount_cents" => 2_000
      },
      overrides
    )
  end

  defp get_group(group_id) do
    conn = get(build_conn(), ~p"/api/v1/groups/#{group_id}")
    json_response(conn, 200)["data"]
  end

  defp get_ledger(query \\ "") do
    conn = get(build_conn(), "/api/v1/ledger" <> query)
    json_response(conn, 200)["data"]
  end

  defp get_credit(guest_id, query \\ "") do
    conn = get(build_conn(), "/api/v1/guests/#{guest_id}/credit" <> query)
    json_response(conn, 200)["data"]
  end

  defp get_payment(payment_operation_id) do
    get(build_conn(), ~p"/api/v1/payments/#{payment_operation_id}")
  end

  # Opens, funds, and refunds a flexible group into a hotel credit lot of
  # `cash_cents` + 10%, usable by the same guest.
  defp issue_credit(conn, guest_id, group_id, cash_cents) do
    operations = [
      open_op(%{
        "operation_id" => "op-open-#{group_id}",
        "group_id" => group_id,
        "guest_id" => guest_id
      }),
      payment_op(%{
        "operation_id" => "op-pay-#{group_id}",
        "group_id" => group_id,
        "amount_cents" => cash_cents
      }),
      %{
        "operation_id" => "op-cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-20",
        "group_id" => group_id,
        "refund_method" => "hotel_credit"
      }
    ]

    conn = post_batch(conn, %{"operations" => operations})
    assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)
  end

  # Seeds a source group with 2_000 of legacy cash (no durable identity)
  # held on room-a, like the room-accounting migration left behind.
  defp seed_legacy_group do
    {:ok, group} =
      %Group{}
      |> Ecto.Changeset.change(
        group_id: "group-legacy",
        guest_id: "guest-22",
        property_id: "ams-canal",
        rate_plan: "flexible",
        status: "active",
        revision: 1,
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-13],
        policy_version: "flex-14",
        lodging_total_cents: 45_000,
        deposit_due_cents: 9_000,
        deposit_paid_cents: 2_000,
        cash_paid_cents: 2_000
      )
      |> Repo.insert()

    {:ok, room} =
      %Room{}
      |> Ecto.Changeset.change(
        group_id: group.id,
        position: 0,
        room_id: "room-a",
        nightly_rate_cents: 15_000,
        status: "active",
        lodging_total_cents: 45_000,
        deposit_due_cents: 9_000,
        cash_paid_cents: 2_000
      )
      |> Repo.insert()

    {:ok, _allocation} =
      %CashAllocation{}
      |> Ecto.Changeset.change(
        group_id: group.id,
        room_id: room.id,
        payment_operation_id: nil,
        amount_cents: 2_000,
        status: "held"
      )
      |> Repo.insert()

    group
  end

  describe "transfer_deposit" do
    test "moves held cash into the destination's outstanding deposit", %{conn: conn} do
      operations = [
        open_op(),
        open_one_room_op("group-82"),
        payment_op(%{"amount_cents" => 5_000}),
        transfer_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-transfer",
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-82",
               "amount_cents" => 2_000,
               "source_outstanding_deposit_cents" => 16_500,
               "destination_outstanding_deposit_cents" => 6_000,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      source = get_group("group-81")
      assert source["cash_paid_cents"] == 3_000
      assert source["outstanding_deposit_cents"] == 16_500

      destination = get_group("group-82")
      assert destination["cash_paid_cents"] == 2_000
      assert destination["outstanding_deposit_cents"] == 6_000

      # a transfer never moves money through a provider
      assert %{"cash_held_cents" => 5_000} = get_ledger()
    end

    test "both groups' revisions increment even when the batch addresses them together", %{
      conn: conn
    } do
      operations = [
        open_op(),
        open_one_room_op("group-82"),
        payment_op(%{"amount_cents" => 5_000}),
        # destination's first revision comes from the same batch
        transfer_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)

      assert result["source_revision"] == 3
      assert result["destination_revision"] == 2

      # the destination's stale guard observes the same-batch increment
      conn =
        post_batch(build_conn(), %{
          "operations" => [
            transfer_op(%{"operation_id" => "op-again", "destination_expected_revision" => 1})
          ]
        })

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "stale_revision"
      assert result["group_id"] == "group-82"
      assert result["expected_revision"] == 1
      assert result["actual_revision"] == 2
    end

    test "draws the most recent allocation first regardless of funding kind", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      operations = [
        open_op(),
        open_one_room_op("group-83", %{"guest_id" => "guest-22"}),
        # credit fills room-a's remaining 5_000? no: credit applied first, 4_000
        credit_op(),
        # cash of 4_000 lands afterward and is therefore the most recent
        payment_op(%{"amount_cents" => 4_000}),
        transfer_op(%{"destination_group_id" => "group-83", "amount_cents" => 6_000})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})
      assert %{"results" => [_, _, credit, payment, _result]} = json_response(conn, 200)
      assert credit["status"] == "applied"
      assert payment["status"] == "applied"

      # the most recent funding is the 4_000 of cash; the older 4_000 of
      # credit contributes the rest, drawn after
      destination = get_group("group-83")

      assert [%{"cash_paid_cents" => 4_000, "credit_paid_cents" => 2_000}] =
               destination["rooms"]

      # the source keeps the older credit's remainder
      source = get_group("group-81")
      assert source["cash_paid_cents"] == 0
      assert source["credit_paid_cents"] == 2_000

      # moved credit remains applied with its expiry paused: ledger unchanged
      assert %{
               "cash_held_cents" => 4_000,
               "credit_liability_cents" => 11_000
             } = get_ledger()
    end

    test "fills destination rooms in their original order with the draw order", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 10_500}),
        # destination rooms with deposits 1_800 and 3_150
        open_one_room_op("group-84", %{
          "rooms" => [
            %{"room_id" => "room-x", "nightly_rate_cents" => 3_000},
            %{"room_id" => "room-y", "nightly_rate_cents" => 5_250}
          ],
          "departure_on" => "2026-12-13"
        }),
        transfer_op(%{"destination_group_id" => "group-84", "amount_cents" => 4_950})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)
      assert result["status"] == "applied"

      # the newest allocation of the source (1_500 on room-b) moves first,
      # followed by 3_450 of room-a's older allocation
      destination = get_group("group-84")

      assert [
               %{"room_id" => "room-x", "cash_paid_cents" => 1_800},
               %{"room_id" => "room-y", "cash_paid_cents" => 3_150}
             ] = destination["rooms"]

      assert destination["outstanding_deposit_cents"] == 0

      source = get_group("group-81")

      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 5_550},
               %{"room_id" => "room-b", "cash_paid_cents" => 0}
             ] = source["rooms"]
    end

    test "fully consumes a drawn unit across several destination rooms", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"amount_cents" => 2_000}),
        # destination rooms with deposits 800 and 2_400
        open_one_room_op("group-84", %{
          "rooms" => [
            %{"room_id" => "room-x", "nightly_rate_cents" => 2_000},
            %{"room_id" => "room-y", "nightly_rate_cents" => 6_000}
          ]
        }),
        transfer_op(%{"destination_group_id" => "group-84", "amount_cents" => 2_000})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)
      assert result["status"] == "applied"

      destination = get_group("group-84")

      assert [
               %{"room_id" => "room-x", "cash_paid_cents" => 800},
               %{"room_id" => "room-y", "cash_paid_cents" => 1_200}
             ] = destination["rooms"]

      source = get_group("group-81")
      assert Enum.all?(source["rooms"], &(&1["cash_paid_cents"] == 0))

      # the source owns no empty remainder of the payment
      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "held_by_group" => [%{"group_id" => "group-84", "amount_cents" => 2_000}]
               }
             } = json_response(conn, 200)
    end

    test "rejects the same group and different guests with invalid_transfer", %{conn: conn} do
      operations = [
        open_op(),
        open_op(%{
          "operation_id" => "op-open-other",
          "group_id" => "group-99",
          "guest_id" => "guest-77"
        }),
        transfer_op(%{"operation_id" => "op-t1", "destination_group_id" => "group-81"}),
        transfer_op(%{"operation_id" => "op-t2", "destination_group_id" => "group-99"})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, same, different]} = json_response(conn, 200)
      assert same["code"] == "invalid_transfer"
      assert different["code"] == "invalid_transfer"

      assert get_group("group-81")["revision"] == 1
      assert get_group("group-99")["revision"] == 1
    end

    test "resolves source existence before destination existence", %{conn: conn} do
      operations = [
        open_op(),
        transfer_op(%{
          "operation_id" => "op-t1",
          "source_group_id" => "group-missing",
          "destination_group_id" => "group-also-missing"
        }),
        transfer_op(%{"operation_id" => "op-t2", "destination_group_id" => "group-missing"})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, source_missing, destination_missing]} = json_response(conn, 200)

      assert source_missing["code"] == "group_not_found"
      assert source_missing["group_id"] == "group-missing"

      assert destination_missing["code"] == "group_not_found"
      assert destination_missing["group_id"] == "group-missing"
    end

    test "rejects an inactive side with that group's group_id", %{conn: conn} do
      operations = [
        open_op(),
        open_one_room_op("group-82"),
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-81"
        },
        transfer_op(%{"operation_id" => "op-inactive-source"}),
        open_one_room_op("group-83"),
        %{
          "operation_id" => "op-cancel-82",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-82"
        },
        transfer_op(%{
          "operation_id" => "op-inactive-destination",
          "source_group_id" => "group-83"
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, inactive_source, _, _, inactive_destination]} =
               json_response(conn, 200)

      assert inactive_source["code"] == "group_not_active"
      assert inactive_source["group_id"] == "group-81"

      assert inactive_destination["code"] == "group_not_active"
      assert inactive_destination["group_id"] == "group-82"
    end

    test "rejects unusable amounts and overruns", %{conn: conn} do
      operations = [
        open_op(),
        open_one_room_op("group-82"),
        # destination with a small 400 outstanding deposit
        open_one_room_op("group-86", %{
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 1_000}]
        }),
        payment_op(%{"amount_cents" => 1_000}),
        transfer_op(%{"operation_id" => "op-t0", "amount_cents" => 0}),
        transfer_op(%{"operation_id" => "op-t1", "amount_cents" => -100}),
        transfer_op(%{"operation_id" => "op-t2", "amount_cents" => "1000"}),
        transfer_op(%{"operation_id" => "op-t3", "amount_cents" => 1_001}),
        transfer_op(%{
          "operation_id" => "op-t4",
          "destination_group_id" => "group-86",
          "amount_cents" => 500
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, _, zero, negative, string, over_held, over_outstanding]} =
               json_response(conn, 200)

      assert zero["code"] == "invalid_amount"
      assert negative["code"] == "invalid_amount"
      assert string["code"] == "invalid_amount"
      assert over_held["code"] == "transfer_exceeds_held_funding"
      assert over_outstanding["code"] == "transfer_exceeds_outstanding"

      # nothing moved
      assert get_group("group-81")["cash_paid_cents"] == 1_000
      assert get_group("group-82")["cash_paid_cents"] == 0
    end

    test "checks the source revision before the destination revision", %{conn: conn} do
      operations = [
        open_op(),
        open_one_room_op("group-82"),
        transfer_op(%{"expected_revision" => 5, "destination_expected_revision" => 99}),
        transfer_op(%{"operation_id" => "op-t2", "destination_expected_revision" => 99})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, source_stale, dest_stale]} = json_response(conn, 200)

      assert source_stale["code"] == "stale_revision"
      assert source_stale["group_id"] == "group-81"
      assert source_stale["expected_revision"] == 5
      assert source_stale["actual_revision"] == 1

      assert dest_stale["code"] == "stale_revision"
      assert dest_stale["group_id"] == "group-82"
      assert dest_stale["expected_revision"] == 99
      assert dest_stale["actual_revision"] == 1
    end

    test "is durably idempotent and does not move funding twice", %{conn: conn} do
      operations = [open_op(), open_one_room_op("group-82"), payment_op(), transfer_op()]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, result]} = json_response(conn, 200)

      conn = post_batch(build_conn(), %{"operations" => [transfer_op()]})
      assert %{"results" => [retry]} = json_response(conn, 200)
      assert retry == result

      assert %{"cash_held_cents" => 5_000} = get_ledger()
      assert get_group("group-82")["cash_paid_cents"] == 2_000

      # reusing the identifier with a different amount conflicts
      conn =
        post_batch(build_conn(), %{"operations" => [transfer_op(%{"amount_cents" => 1_000})]})

      assert %{"results" => [conflict]} = json_response(conn, 200)
      assert conflict["code"] == "operation_id_conflict"
    end

    test "legacy block funding moves and keeps the unattributed identity", %{conn: conn} do
      seed_legacy_group()

      operations = [
        open_one_room_op("group-82"),
        transfer_op(%{"source_group_id" => "group-legacy", "amount_cents" => 2_000})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["status"] == "applied"

      assert get_group("group-legacy")["cash_paid_cents"] == 0
      assert get_group("group-82")["cash_paid_cents"] == 2_000

      # the moved cash still has no durable identity and cannot be targeted
      conn =
        post_batch(build_conn(), %{
          "operations" => [
            %{
              "operation_id" => "op-reduce",
              "type" => "reduce_cash_payment",
              "occurred_on" => "2026-10-06",
              "payment_operation_id" => "group-legacy",
              "amount_cents" => 100
            }
          ]
        })

      assert %{"results" => [reduce]} = json_response(conn, 200)
      assert reduce["code"] == "operation_not_found"
      assert %{"cash_held_cents" => 2_000} = get_ledger()
    end
  end

  describe "later settlement of transferred funding" do
    test "transferred cash settles under the destination's policy", %{conn: conn} do
      operations = [
        open_op(),
        open_one_room_op("group-82"),
        payment_op(%{"amount_cents" => 5_000}),
        transfer_op(),
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-82"
        }
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, _, cancel]} = json_response(conn, 200)

      # refundable: the moved cash refunds from the destination
      assert cancel["refunded_cents"] == 2_000
      assert cancel["status"] == "applied"

      assert %{"cash_refunded_cents" => 2_000, "cash_held_cents" => 3_000} = get_ledger()

      conn = get_payment("op-pay")

      assert %{"data" => %{"held_cents" => 3_000, "refunded_cents" => 2_000}} =
               json_response(conn, 200)
    end

    test "transferred cash converted at the destination earns the usual bonus", %{conn: conn} do
      operations = [
        open_op(),
        open_one_room_op("group-82"),
        payment_op(%{"amount_cents" => 5_000}),
        transfer_op(),
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-82",
          "refund_method" => "hotel_credit"
        }
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, _, cancel]} = json_response(conn, 200)
      assert cancel["status"] == "applied"
      # 2_000 moved cash, 10% bonus once, at the destination's settlement
      assert cancel["credit_issued_cents"] == 2_200

      assert get_credit("guest-22")["available_cents"] == 2_200

      conn = get_payment("op-pay")
      assert %{"data" => %{"converted_to_credit_cents" => 2_000}} = json_response(conn, 200)
    end

    test "transferred credit restores to its original lot on refundable settlement", %{
      conn: conn
    } do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      operations = [
        open_op(),
        credit_op(),
        open_one_room_op("group-82"),
        transfer_op(%{"destination_group_id" => "group-82", "amount_cents" => 2_000}),
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-82"
        }
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})
      assert %{"results" => [_, credit, _, transfer, cancel]} = json_response(conn, 200)
      assert credit["status"] == "applied"
      assert transfer["status"] == "applied"
      assert cancel["status"] == "applied"
      assert cancel["refunded_cents"] == 0
      assert cancel["credit_issued_cents"] == 0

      # the moved credit returns to its lot with the original expiry
      credit_position = get_credit("guest-22")
      assert credit_position["available_cents"] == 9_000

      assert [
               %{
                 "source_operation_id" => "op-cancel-group-91",
                 "remaining_cents" => 9_000,
                 "expires_on" => "2027-11-20"
               }
             ] = credit_position["lots"]
    end

    test "non-refundable settlement of the destination consumes transferred credit", %{
      conn: conn
    } do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      operations = [
        open_op(),
        credit_op(),
        open_one_room_op("group-82"),
        transfer_op(%{"amount_cents" => 2_000}),
        # two days before arrival: non-refundable
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-08",
          "group_id" => "group-82"
        }
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})
      assert %{"results" => [_, _, _, _, cancel]} = json_response(conn, 200)
      assert cancel["status"] == "applied"

      # the lot shrinks by the consumed 2_000; the 2_000 still funding
      # group-81 stays applied
      assert get_credit("guest-22")["available_cents"] == 7_000
      assert %{"credit_liability_cents" => 9_000} = get_ledger()
    end
  end

  describe "reductions and chargebacks across groups" do
    test "a reduction follows the payment's allocations across groups", %{conn: conn} do
      operations = [
        open_op(),
        open_one_room_op("group-82"),
        payment_op(%{"amount_cents" => 5_000}),
        transfer_op(),
        %{
          "operation_id" => "op-reduce",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-06",
          "payment_operation_id" => "op-pay",
          "amount_cents" => 3_000
        }
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, _, reduce]} = json_response(conn, 200)

      # the most recent allocation first: the moved 2_000, then 1_000 back
      # from the source's remainder
      assert reduce["status"] == "applied"
      assert reduce["group_id"] == "group-81"
      # the single revision in the result is the original group's
      assert reduce["revision"] == 4
      assert reduce["outstanding_deposit_cents"] == 17_500

      destination = get_group("group-82")
      assert destination["outstanding_deposit_cents"] == 8_000
      # every touched group increments
      assert destination["revision"] == 3

      conn = get_payment("op-pay")

      assert %{"data" => %{"held_cents" => 2_000, "reduced_cents" => 3_000}} =
               json_response(conn, 200)

      # the statement still knows where what remains sits
      assert %{"held_by_group" => [%{"group_id" => "group-81", "amount_cents" => 2_000}]} =
               json_response(conn, 200)["data"]
    end

    test "a chargeback reopens outstanding in whichever group holds the cash", %{conn: conn} do
      operations = [
        open_op(),
        open_one_room_op("group-82"),
        payment_op(%{"amount_cents" => 5_000}),
        transfer_op(),
        %{
          "operation_id" => "op-chargeback",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-10-06",
          "payment_operation_id" => "op-pay"
        }
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, _, chargeback]} = json_response(conn, 200)

      assert chargeback["status"] == "applied"
      assert chargeback["charged_back_cents"] == 5_000
      assert chargeback["group_id"] == "group-81"

      destination = get_group("group-82")
      assert destination["outstanding_deposit_cents"] == 8_000
      assert destination["revision"] == 3

      assert get_group("group-81")["outstanding_deposit_cents"] == 19_500
    end

    test "a moved payment settles at the destination and the clawback follows it", %{
      conn: conn
    } do
      operations = [
        open_op(),
        open_one_room_op("group-82"),
        payment_op(%{"amount_cents" => 5_000}),
        transfer_op(),
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-82",
          "refund_method" => "hotel_credit"
        },
        %{
          "operation_id" => "op-chargeback",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-11-21",
          "payment_operation_id" => "op-pay"
        }
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, _, _, chargeback]} = json_response(conn, 200)
      assert chargeback["status"] == "applied"
      assert chargeback["charged_back_cents"] == 5_000

      # the destination's converted entitlement is revoked, down to the
      # moved portion
      assert get_credit("guest-22")["available_cents"] == 0
      assert %{"credit_liability_cents" => 0, "cash_charged_back_cents" => 5_000} = get_ledger()
    end
  end

  describe "payment statement evolution" do
    test "retains the original shape until funding participates in a transfer", %{conn: conn} do
      operations = [open_op(), open_one_room_op("group-82"), payment_op()]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _]} = json_response(conn, 200)

      conn = get_payment("op-pay")
      data = json_response(conn, 200)["data"]
      refute Map.has_key?(data, "held_by_group")
      assert data["held_cents"] == 5_000
    end

    test "adds held_by_group ordered by group_id", %{conn: conn} do
      operations = [
        open_one_room_op("group-9"),
        open_one_room_op("group-2"),
        payment_op(%{
          "operation_id" => "op-pay",
          "group_id" => "group-9",
          "amount_cents" => 5_000
        }),
        transfer_op(%{
          "operation_id" => "op-t1",
          "source_group_id" => "group-9",
          "destination_group_id" => "group-2",
          "amount_cents" => 1_000
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, _]} = json_response(conn, 200)

      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "held_cents" => 5_000,
                 "held_by_group" => [
                   %{"group_id" => "group-2", "amount_cents" => 1_000},
                   %{"group_id" => "group-9", "amount_cents" => 4_000}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "omits groups with no held cash and returns an empty list when none remains", %{
      conn: conn
    } do
      operations = [
        open_op(),
        open_one_room_op("group-82"),
        payment_op(%{"amount_cents" => 5_000}),
        transfer_op(),
        # move the rest of the payment's held cash into the destination too
        transfer_op(%{"operation_id" => "op-t2", "amount_cents" => 3_000}),
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-82"
        }
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, _, _, cancel]} = json_response(conn, 200)
      assert cancel["status"] == "applied"

      conn = get_payment("op-pay")

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "refunded_cents" => 5_000,
                 "held_by_group" => []
               }
             } = json_response(conn, 200)
    end
  end
end
