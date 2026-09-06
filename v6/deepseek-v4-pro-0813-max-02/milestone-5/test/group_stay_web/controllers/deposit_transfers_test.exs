defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.ApiHelpers

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo
  alias GroupStay.RoomAccounting

  defp post_ops(ops) do
    api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => ops})
  end

  defp get_group(group_id) do
    {body, 200} = api_get(build_conn(), "/api/v1/groups/#{group_id}")
    body["data"]
  end

  defp get_ledger(query \\ "") do
    api_get(build_conn(), "/api/v1/ledger#{query}")
  end

  defp get_credit do
    api_get(build_conn(), "/api/v1/guests/guest-22/credit")
  end

  defp get_payment(payment_operation_id) do
    api_get(build_conn(), "/api/v1/payments/#{payment_operation_id}")
  end

  defp result(body, index \\ 0) do
    Enum.at(body["results"], index)
  end

  defp destination_op(overrides \\ %{}) do
    open_group_op(%{
      "operation_id" => "op-1002",
      "group_id" => "group-92",
      "occurred_on" => "2026-10-03",
      "guest_id" => "guest-22",
      "property_id" => "ams-plaza",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-x", "nightly_rate_cents" => 20_000},
        %{"room_id" => "room-y", "nightly_rate_cents" => 30_000}
      ]
    })
    |> Map.merge(overrides)
  end

  # Issues 5,500 cents of hotel credit to guest-22 in lot "op-9103",
  # expiring 2027-04-01.
  defp issue_credit do
    open =
      open_group_op(%{
        "operation_id" => "op-9101",
        "group_id" => "group-91",
        "occurred_on" => "2026-01-05",
        "guest_id" => "guest-22",
        "arrival_on" => "2026-06-01",
        "departure_on" => "2026-06-04",
        "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 12_500}]
      })

    payment =
      cash_payment_op(%{
        "operation_id" => "op-9102",
        "group_id" => "group-91",
        "occurred_on" => "2026-01-06",
        "amount_cents" => 5_000
      })

    cancellation =
      cancel_op(%{
        "operation_id" => "op-9103",
        "group_id" => "group-91",
        "occurred_on" => "2026-04-01",
        "refund_method" => "hotel_credit"
      })

    {_, 200} = post_ops([open, payment, cancellation])
    :ok
  end

  describe "applied transfers" do
    test "moves held funding between groups and reports both sides" do
      {_, 200} = post_ops([open_group_op(), destination_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 15_000})])

      # group-81 rooms: a due 9,000; b due 10,500. 15,000 pays a fully and
      # 6,000 into b. Moving 4,000 drains the newest allocation first.
      {body, 200} = post_ops([transfer_deposit_op(%{"amount_cents" => 4_000})])

      assert result(body) == %{
               "operation_id" => "op-9001",
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-92",
               "amount_cents" => 4_000,
               "source_outstanding_deposit_cents" => 8_500,
               "destination_outstanding_deposit_cents" => 26_000,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      source = get_group("group-81")
      assert source["revision"] == 3
      assert source["deposit_paid_cents"] == 11_000
      assert source["outstanding_deposit_cents"] == 8_500

      assert Enum.map(source["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) == [
               {"room-a", 9_000},
               {"room-b", 2_000}
             ]

      destination = get_group("group-92")
      assert destination["revision"] == 2
      assert destination["deposit_paid_cents"] == 4_000
      assert destination["outstanding_deposit_cents"] == 26_000

      assert Enum.map(destination["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) == [
               {"room-x", 4_000},
               {"room-y", 0}
             ]

      # The transfer only moves funding between rooms; the ledger is the
      # same as before.
      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_held_cents"] == 15_000

      {payment, 200} = get_payment("op-2001")
      assert payment["data"]["held_cents"] == 15_000

      assert payment["data"]["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 11_000},
               %{"group_id" => "group-92", "amount_cents" => 4_000}
             ]
    end

    test "drains in reverse allocation order regardless of funding kind" do
      issue_credit()

      {_, 200} = post_ops([open_group_op(), destination_op()])

      {_, 200} =
        post_ops([
          cash_payment_op(%{"amount_cents" => 9_000}),
          apply_hotel_credit_op(%{"occurred_on" => "2026-10-20", "amount_cents" => 5_500})
        ])

      # room-a holds 9,000 cash (allocated first); room-b holds 5,500
      # credit (allocated second). Draining 8,000 takes the credit first
      # and then 2,500 of the cash.
      {ledger_before, 200} = get_ledger()
      credit_before = elem(get_credit(), 0)

      {body, 200} =
        post_ops([transfer_deposit_op(%{"amount_cents" => 8_000, "expected_revision" => 3})])

      assert result(body)["status"] == "applied"

      source = get_group("group-81")

      assert Enum.map(
               source["rooms"],
               &{&1["room_id"], &1["cash_paid_cents"], &1["credit_paid_cents"]}
             ) ==
               [{"room-a", 6_500, 0}, {"room-b", 0, 0}]

      # Drawn units fill the destination's rooms in the order they were
      # drawn: the credit slice first, then the cash slice.
      destination = get_group("group-92")
      assert destination["deposit_paid_cents"] == 8_000

      assert Enum.map(
               destination["rooms"],
               &{&1["room_id"], &1["cash_paid_cents"], &1["credit_paid_cents"]}
             ) == [{"room-x", 2_500, 5_500}, {"room-y", 0, 0}]

      # The transfer settles nothing: no ledger movement, no new credit, no
      # resumed expiry.
      assert elem(get_ledger(), 0) == ledger_before
      assert elem(get_credit(), 0) == credit_before

      {credit, 200} = get_credit()
      assert credit["data"]["available_cents"] == 0
      assert credit["data"]["lots"] == []

      # Refundable settlement of the destination restores the credit to its
      # original lot and expiry without another bonus, and refunds the moved
      # cash.
      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-9201",
            "group_id" => "group-92",
            "occurred_on" => "2026-11-01"
          })
        ])

      {credit, 200} = get_credit()
      assert credit["data"]["available_cents"] == 5_500

      assert credit["data"]["lots"] == [
               %{
                 "source_operation_id" => "op-9103",
                 "remaining_cents" => 5_500,
                 "expires_on" => "2027-04-01"
               }
             ]

      {_, 200} = get_payment("op-2001")
      {payment, 200} = get_payment("op-2001")
      assert payment["data"]["refunded_cents"] == 2_500

      cancelled = get_group("group-92")
      assert cancelled["status"] == "cancelled"
      assert cancelled["refundable_until"] == "2026-11-26"
    end

    test "existing destination funding is filled before the moved slices" do
      {_, 200} = post_ops([open_group_op(), destination_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 15_000})])

      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2003",
            "group_id" => "group-92",
            "amount_cents" => 500
          }),
          transfer_deposit_op(%{"amount_cents" => 4_000})
        ])

      destination = get_group("group-92")

      assert Enum.map(destination["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) == [
               {"room-x", 4_500},
               {"room-y", 0}
             ]
    end

    test "can move the entire held funding and transfer the same payment again" do
      {_, 200} = post_ops([open_group_op(), destination_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 15_000})])

      {body, 200} =
        post_ops([
          transfer_deposit_op(%{"operation_id" => "op-9001", "amount_cents" => 15_000})
        ])

      assert result(body)["status"] == "applied"
      assert result(body)["source_outstanding_deposit_cents"] == 19_500
      assert result(body)["destination_outstanding_deposit_cents"] == 15_000

      source = get_group("group-81")
      assert source["deposit_paid_cents"] == 0
      assert source["outstanding_deposit_cents"] == 19_500

      destination = get_group("group-92")

      assert Enum.map(destination["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) == [
               {"room-x", 12_000},
               {"room-y", 3_000}
             ]

      {body, 200} = get_payment("op-2001")
      assert body["data"]["held_cents"] == 15_000

      assert body["data"]["held_by_group"] == [
               %{"group_id" => "group-92", "amount_cents" => 15_000}
             ]

      # Nothing is held in the source anymore.
      {body, 200} =
        post_ops([transfer_deposit_op(%{"operation_id" => "op-9002", "amount_cents" => 1})])

      assert result(body)["code"] == "transfer_exceeds_held_funding"
      assert get_group("group-81")["revision"] == 3
      assert get_group("group-92")["revision"] == 2

      # Move part of it back: the same payment participates in a second
      # transfer.
      {body, 200} =
        post_ops([
          transfer_deposit_op(%{
            "operation_id" => "op-9003",
            "source_group_id" => "group-92",
            "destination_group_id" => "group-81",
            "amount_cents" => 3_000
          })
        ])

      assert result(body)["status"] == "applied"

      {body, 200} = get_payment("op-2001")
      assert body["data"]["held_cents"] == 15_000

      assert body["data"]["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 3_000},
               %{"group_id" => "group-92", "amount_cents" => 12_000}
             ]
    end
  end

  describe "rejections" do
    setup do
      {_, 200} = post_ops([open_group_op(), destination_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])
      :ok
    end

    test "rejects transfers between the same group or guests" do
      for {overrides, index} <-
            Enum.with_index([
              %{"destination_group_id" => "group-81"},
              %{"destination_group_id" => "group-93"}
            ]) do
        if overrides["destination_group_id"] == "group-93" do
          {_, 200} =
            post_ops([
              destination_op(%{
                "group_id" => "group-93",
                "operation_id" => "op-1093",
                "guest_id" => "guest-23"
              })
            ])
        end

        {body, 200} =
          post_ops([
            transfer_deposit_op(%{"operation_id" => "op-t#{index}"} |> Map.merge(overrides))
          ])

        assert result(body) == %{
                 "operation_id" => "op-t#{index}",
                 "status" => "rejected",
                 "code" => "invalid_transfer"
               }
      end

      assert get_group("group-81")["revision"] == 2
      assert get_group("group-92")["revision"] == 1

      # The same-group rule is checked before the amount rule.
      {body, 200} =
        post_ops([
          transfer_deposit_op(%{
            "operation_id" => "op-t9",
            "destination_group_id" => "group-81",
            "amount_cents" => 0
          })
        ])

      assert result(body)["code"] == "invalid_transfer"
    end

    test "resolves source existence before destination existence" do
      {body, 200} =
        post_ops([
          transfer_deposit_op(%{
            "operation_id" => "op-t1",
            "source_group_id" => "group-missing",
            "destination_group_id" => "group-missing-too"
          })
        ])

      assert result(body) == %{
               "operation_id" => "op-t1",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-missing"
             }

      {body, 200} =
        post_ops([
          transfer_deposit_op(%{
            "operation_id" => "op-t2",
            "destination_group_id" => "group-missing"
          })
        ])

      assert result(body) == %{
               "operation_id" => "op-t2",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-missing"
             }
    end

    test "rejects inactive groups with the inactive group id" do
      {_, 200} =
        post_ops([
          destination_op(%{"group_id" => "group-93", "operation_id" => "op-1093"}),
          cancel_op(%{
            "operation_id" => "op-9301",
            "group_id" => "group-93",
            "occurred_on" => "2026-11-26"
          })
        ])

      {body, 200} =
        post_ops([
          transfer_deposit_op(%{
            "operation_id" => "op-t1",
            "destination_group_id" => "group-93",
            "amount_cents" => 1
          })
        ])

      assert result(body) == %{
               "operation_id" => "op-t1",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-93"
             }

      {_, 200} =
        post_ops([
          cancel_op(%{"operation_id" => "op-4001", "occurred_on" => "2026-11-26"})
        ])

      {body, 200} =
        post_ops([
          transfer_deposit_op(%{
            "operation_id" => "op-t2",
            "destination_group_id" => "group-93",
            "amount_cents" => 1
          })
        ])

      assert result(body) == %{
               "operation_id" => "op-t2",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-81"
             }

      assert get_group("group-81")["revision"] == 3
    end

    test "rejects amounts that are not positive integers" do
      for {amount, index} <- Enum.with_index([0, -100, 1.5, "100"]) do
        {body, 200} =
          post_ops([
            transfer_deposit_op(%{"operation_id" => "op-t#{index}", "amount_cents" => amount})
          ])

        assert result(body) == %{
                 "operation_id" => "op-t#{index}",
                 "status" => "rejected",
                 "code" => "invalid_amount"
               }
      end

      assert get_group("group-81")["revision"] == 2
      assert get_group("group-92")["revision"] == 1
    end

    test "rejects transfers exceeding held funding or destination outstanding" do
      {body, 200} =
        post_ops([transfer_deposit_op(%{"operation_id" => "op-t1", "amount_cents" => 5_001})])

      assert result(body) == %{
               "operation_id" => "op-t1",
               "status" => "rejected",
               "code" => "transfer_exceeds_held_funding"
             }

      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2003",
            "group_id" => "group-92",
            "amount_cents" => 30_000
          })
        ])

      {body, 200} =
        post_ops([transfer_deposit_op(%{"operation_id" => "op-t2", "amount_cents" => 500})])

      assert result(body)["code"] == "transfer_exceeds_outstanding"

      assert get_group("group-81")["revision"] == 2
      assert get_group("group-92")["revision"] == 2
    end

    test "rejects operations missing required data with invalid_operation" do
      for op <- [
            %{"operation_id" => "op-t1", "type" => "transfer_deposit"},
            %{
              "operation_id" => "op-t2",
              "type" => "transfer_deposit",
              "source_group_id" => "group-81",
              "destination_group_id" => "group-92"
            },
            %{
              "operation_id" => "op-t3",
              "type" => "transfer_deposit",
              "source_group_id" => 42,
              "destination_group_id" => "group-92",
              "amount_cents" => 100
            }
          ] do
        {body, 200} = post_ops([op])
        assert result(body)["code"] == "invalid_operation"
      end
    end
  end

  describe "revision guards" do
    setup do
      {_, 200} = post_ops([open_group_op(), destination_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])
      :ok
    end

    test "checks the source revision, then the destination revision, before transfer rules" do
      {body, 200} =
        post_ops([
          transfer_deposit_op(%{
            "operation_id" => "op-t1",
            "expected_revision" => 9,
            "destination_expected_revision" => 9,
            "amount_cents" => 0
          })
        ])

      assert result(body) == %{
               "operation_id" => "op-t1",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 9,
               "actual_revision" => 2
             }

      {body, 200} =
        post_ops([
          transfer_deposit_op(%{
            "operation_id" => "op-t2",
            "destination_expected_revision" => 9,
            "amount_cents" => 0
          })
        ])

      assert result(body) == %{
               "operation_id" => "op-t2",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-92",
               "expected_revision" => 9,
               "actual_revision" => 1
             }
    end

    test "checks the destination revision before the destination's activity" do
      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-9301",
            "group_id" => "group-92",
            "occurred_on" => "2026-11-26"
          })
        ])

      {body, 200} =
        post_ops([
          transfer_deposit_op(%{
            "operation_id" => "op-t1",
            "destination_expected_revision" => 5
          })
        ])

      assert result(body) == %{
               "operation_id" => "op-t1",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-92",
               "expected_revision" => 5,
               "actual_revision" => 2
             }
    end

    test "matching guards allow the transfer and both revisions move" do
      {body, 200} =
        post_ops([
          transfer_deposit_op(%{
            "operation_id" => "op-t1",
            "amount_cents" => 1_000,
            "expected_revision" => 2,
            "destination_expected_revision" => 1
          })
        ])

      assert result(body)["status"] == "applied"
      assert result(body)["source_revision"] == 3
      assert result(body)["destination_revision"] == 2

      assert get_group("group-81")["revision"] == 3
      assert get_group("group-92")["revision"] == 2
    end
  end

  describe "durability and batches" do
    setup do
      {_, 200} = post_ops([open_group_op(), destination_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])
      :ok
    end

    test "operations in one batch observe earlier operations in the same batch" do
      open_source = open_group_op()
      open_dest = destination_op()
      payment = cash_payment_op(%{"amount_cents" => 5_000})
      transfer = transfer_deposit_op(%{"amount_cents" => 2_000})

      {body, 200} = post_ops([open_source, open_dest, payment, transfer])

      assert result(body, 3)["status"] == "applied"
      assert result(body, 3)["source_revision"] == 3
      assert result(body, 3)["destination_revision"] == 2

      assert get_group("group-81")["deposit_paid_cents"] == 3_000
      assert get_group("group-92")["deposit_paid_cents"] == 2_000
    end

    test "an equivalent retry returns the exact stored result without moving funding again" do
      {body, 200} = post_ops([transfer_deposit_op(%{"amount_cents" => 2_000})])
      applied = result(body)

      source_before = get_group("group-81")
      destination_before = get_group("group-92")

      {retry_body, 200} =
        post_ops([
          %{
            "amount_cents" => 2_000,
            "destination_group_id" => "group-92",
            "operation_id" => "op-9001",
            "source_group_id" => "group-81",
            "type" => "transfer_deposit"
          }
        ])

      assert result(retry_body) == applied
      assert get_group("group-81") == source_before
      assert get_group("group-92") == destination_before

      {stored, 200} = api_get(build_conn(), "/api/v1/operations/op-9001")
      assert stored == %{"data" => applied}
    end

    test "reusing the identifier with a different payload conflicts" do
      {body, 200} = post_ops([transfer_deposit_op(%{"amount_cents" => 2_000})])
      applied = result(body)

      {body, 200} =
        post_ops([transfer_deposit_op(%{"operation_id" => "op-9001", "amount_cents" => 1})])

      assert result(body) == %{
               "operation_id" => "op-9001",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      {stored, 200} = api_get(build_conn(), "/api/v1/operations/op-9001")
      assert stored == %{"data" => applied}
      assert get_group("group-81")["deposit_paid_cents"] == 3_000
    end

    test "a stored rejection is returned on an equivalent retry" do
      rejected =
        transfer_deposit_op(%{
          "operation_id" => "op-t1",
          "amount_cents" => 0
        })

      {body, 200} = post_ops([rejected])
      stored = result(body)
      assert stored["code"] == "invalid_amount"

      {_, 200} = post_ops([cash_payment_op(%{"operation_id" => "op-2002", "amount_cents" => 1})])

      {retry_body, 200} = post_ops([rejected])
      assert result(retry_body) == stored
    end
  end

  describe "observing transferred funding" do
    test "payments that never participated in a transfer keep the old statement shape" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 5_000})])

      {body, 200} = get_payment("op-2001")
      refute Map.has_key?(body["data"], "held_by_group")

      {_, 200} = post_ops([cancel_op(%{"occurred_on" => "2026-11-26"})])

      {body, 200} = get_payment("op-2001")
      refute Map.has_key?(body["data"], "held_by_group")
    end

    test "held_by_group is ordered by group_id and omits groups with no held cash" do
      {_, 200} = post_ops([open_group_op(), destination_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 15_000})])

      {_, 200} =
        post_ops([
          transfer_deposit_op(%{"amount_cents" => 4_000}),
          reduce_cash_payment_op(%{"operation_id" => "op-7001", "amount_cents" => 2_000})
        ])

      # The reduction drains the newest allocations first: 2,000 of the
      # 4,000 transferred to group-92.
      {body, 200} = get_payment("op-2001")
      assert body["data"]["held_cents"] == 13_000

      assert body["data"]["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 11_000},
               %{"group_id" => "group-92", "amount_cents" => 2_000}
             ]

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_held_cents"] == 13_000
      assert ledger["data"]["cash_reduced_cents"] == 2_000
    end

    test "held_by_group uses the destination's alphabetical group identifiers" do
      {_, 200} =
        post_ops([
          open_group_op(),
          destination_op(%{"group_id" => "group-05", "operation_id" => "op-1005"})
        ])

      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 15_000})])

      {_, 200} =
        post_ops([
          transfer_deposit_op(%{
            "operation_id" => "op-9001",
            "destination_group_id" => "group-05",
            "amount_cents" => 1_000
          })
        ])

      {body, 200} = get_payment("op-2001")

      assert Enum.map(body["data"]["held_by_group"], & &1["group_id"]) == [
               "group-05",
               "group-81"
             ]
    end

    test "held_by_group becomes an empty list once nothing remains held" do
      {_, 200} = post_ops([open_group_op(), destination_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 15_000})])

      {_, 200} = post_ops([transfer_deposit_op(%{"amount_cents" => 4_000})])

      {_, 200} =
        post_ops([
          reduce_cash_payment_op(%{"operation_id" => "op-7001", "amount_cents" => 15_000})
        ])

      {body, 200} = get_payment("op-2001")
      assert body["data"]["held_cents"] == 0
      assert body["data"]["held_by_group"] == []
    end
  end

  describe "later settlement and corrections" do
    test "transferred cash settles under the destination group's cancellation policy" do
      {_, 200} =
        post_ops([
          open_group_op(),
          destination_op(%{
            "operation_id" => "op-1002",
            "rate_plan" => "advance_purchase"
          })
        ])

      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 10_000})])

      {_, 200} = post_ops([transfer_deposit_op(%{"amount_cents" => 4_000})])

      {body, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-9201",
            "group_id" => "group-92",
            "occurred_on" => "2026-11-26"
          })
        ])

      assert result(body)["refunded_cents"] == 0
      assert result(body)["retained_cents"] == 4_000

      assert get_group("group-81")["status"] == "active"
      assert get_group("group-92")["status"] == "cancelled"

      {body, 200} = get_payment("op-2001")
      assert body["data"]["held_cents"] == 6_000
      assert body["data"]["retained_cents"] == 4_000

      assert body["data"]["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 6_000}
             ]

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_held_cents"] == 6_000
      assert ledger["data"]["cash_retained_cents"] == 4_000
    end

    test "transferred cash converts to hotel credit under the destination's policy" do
      {_, 200} = post_ops([open_group_op(), destination_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 10_000})])

      {_, 200} = post_ops([transfer_deposit_op(%{"amount_cents" => 4_000})])

      {body, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-9201",
            "group_id" => "group-92",
            "occurred_on" => "2026-11-01",
            "refund_method" => "hotel_credit"
          })
        ])

      assert result(body)["refunded_cents"] == 0
      assert result(body)["retained_cents"] == 0
      assert result(body)["credit_issued_cents"] == 4_400

      {credit, 200} = get_credit()
      assert credit["data"]["available_cents"] == 4_400

      assert credit["data"]["lots"] == [
               %{
                 "source_operation_id" => "op-9201",
                 "remaining_cents" => 4_400,
                 "expires_on" => "2027-11-01"
               }
             ]

      {body, 200} = get_payment("op-2001")
      assert body["data"]["converted_to_credit_cents"] == 4_000
      assert body["data"]["held_cents"] == 6_000

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_converted_to_credit_cents"] == 4_000
      assert ledger["data"]["credit_liability_cents"] == 4_400
    end

    test "reductions follow the payment across groups and bump every affected revision" do
      {_, 200} = post_ops([open_group_op(), destination_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 15_000})])

      {_, 200} = post_ops([transfer_deposit_op(%{"amount_cents" => 4_000})])

      # Held cash: group-92 holds 4,000 (newest), then group-81 holds 2,000
      # in room-b and 9,000 in room-a. A 12,000 reduction drains group-92,
      # then room-b, then 6,000 of room-a.
      {body, 200} =
        post_ops([
          reduce_cash_payment_op(%{"operation_id" => "op-7001", "amount_cents" => 12_000})
        ])

      assert result(body) == %{
               "operation_id" => "op-7001",
               "status" => "applied",
               "payment_operation_id" => "op-2001",
               "group_id" => "group-81",
               "amount_cents" => 12_000,
               "outstanding_deposit_cents" => 16_500,
               "revision" => 4
             }

      source = get_group("group-81")
      assert source["revision"] == 4

      assert Enum.map(source["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) == [
               {"room-a", 3_000},
               {"room-b", 0}
             ]

      destination = get_group("group-92")
      assert destination["revision"] == 3
      assert destination["deposit_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 30_000

      {body, 200} = get_payment("op-2001")
      assert body["data"]["held_cents"] == 3_000
      assert body["data"]["reduced_cents"] == 12_000

      assert body["data"]["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 3_000}
             ]

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_held_cents"] == 3_000
      assert ledger["data"]["cash_reduced_cents"] == 12_000
    end

    test "a chargeback reclassifies the payment wherever it funds rooms" do
      {_, 200} = post_ops([open_group_op(), destination_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 15_000})])

      {_, 200} = post_ops([transfer_deposit_op(%{"amount_cents" => 4_000})])

      {body, 200} = post_ops([charge_back_payment_op()])

      assert result(body) == %{
               "operation_id" => "op-8001",
               "status" => "applied",
               "payment_operation_id" => "op-2001",
               "group_id" => "group-81",
               "charged_back_cents" => 15_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 4
             }

      source = get_group("group-81")
      assert source["revision"] == 4
      assert source["outstanding_deposit_cents"] == 19_500

      destination = get_group("group-92")
      assert destination["revision"] == 3
      assert destination["deposit_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 30_000

      {body, 200} = get_payment("op-2001")
      assert body["data"]["held_cents"] == 0
      assert body["data"]["charged_back_cents"] == 15_000
      assert body["data"]["held_by_group"] == []

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_held_cents"] == 0
      assert ledger["data"]["cash_charged_back_cents"] == 15_000
    end

    test "a chargeback reaches settled rows moved to another group" do
      {_, 200} = post_ops([open_group_op(), destination_op()])
      {_, 200} = post_ops([cash_payment_op(%{"amount_cents" => 10_000})])

      {_, 200} = post_ops([transfer_deposit_op(%{"amount_cents" => 4_000})])

      # The destination settles refundably: the 4,000 moved there become
      # refunded cash under group-92's policy.
      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-9201",
            "group_id" => "group-92",
            "occurred_on" => "2026-11-01"
          })
        ])

      {body, 200} = post_ops([charge_back_payment_op()])

      assert result(body)["charged_back_cents"] == 10_000
      assert result(body)["outstanding_deposit_cents"] == 19_500
      assert result(body)["revision"] == 4

      # Both groups reclassify the payment and advance: the historical
      # refund is not reversed, it is reclassified.
      assert get_group("group-81")["revision"] == 4
      assert get_group("group-92")["revision"] == 4

      {body, 200} = get_payment("op-2001")
      assert body["data"]["held_cents"] == 0
      assert body["data"]["refunded_cents"] == 0
      assert body["data"]["charged_back_cents"] == 10_000
      assert body["data"]["held_by_group"] == []

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_refunded_cents"] == 0
      assert ledger["data"]["cash_held_cents"] == 0
      assert ledger["data"]["cash_charged_back_cents"] == 10_000
    end

    test "transferred credit settles non-refundably under the destination's policy" do
      issue_credit()

      {_, 200} =
        post_ops([
          open_group_op(),
          destination_op(%{"rate_plan" => "advance_purchase"})
        ])

      {_, 200} =
        post_ops([
          cash_payment_op(%{"amount_cents" => 9_000}),
          apply_hotel_credit_op(%{"occurred_on" => "2026-10-20", "amount_cents" => 5_500})
        ])

      {_, 200} = post_ops([transfer_deposit_op(%{"amount_cents" => 8_000})])

      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-9201",
            "group_id" => "group-92",
            "occurred_on" => "2026-11-26"
          })
        ])

      {credit, 200} = get_credit()
      assert credit["data"]["available_cents"] == 0

      {ledger, 200} = get_ledger()
      assert ledger["data"]["credit_liability_cents"] == 0
      assert ledger["data"]["cash_retained_cents"] == 2_500
    end
  end

  describe "release 04 databases" do
    test "per-group seq rows drain in reverse fill order after the upgrade" do
      alias GroupStay.Operations.Record, as: OperationRecord
      alias GroupStay.RoomAccounting.RoomAllocation

      src =
        Repo.insert!(%Group{
          group_id: "old-src",
          guest_id: "guest-22",
          property_id: "p-1",
          booked_on: ~D[2026-10-03],
          arrival_on: ~D[2026-12-10],
          departure_on: ~D[2026-12-13],
          rate_plan: "flexible",
          status: "active",
          revision: 2,
          policy_version: "flex-14",
          lodging_total_cents: 97_500,
          deposit_due_cents: 19_500,
          deposit_paid_cents: 15_000,
          cash_paid_cents: 15_000
        })

      r1 =
        Repo.insert!(%Room{
          room_id: "room-a",
          nightly_rate_cents: 15_000,
          position: 0,
          status: "active",
          deposit_due_cents: 9_000,
          group_id: src.id
        })

      r2 =
        Repo.insert!(%Room{
          room_id: "room-b",
          nightly_rate_cents: 17_500,
          position: 1,
          status: "active",
          deposit_due_cents: 10_500,
          group_id: src.id
        })

      # Release 04 allocated seq per group, so another group's rows can
      # carry the same seq values.
      Repo.insert!(%RoomAllocation{
        group_id: src.id,
        room_id: r1.id,
        kind: "cash",
        amount_cents: 9_000,
        payment_operation_id: "pay-old",
        disposition: "held",
        seq: 1
      })

      Repo.insert!(%RoomAllocation{
        group_id: src.id,
        room_id: r2.id,
        kind: "cash",
        amount_cents: 6_000,
        payment_operation_id: "pay-old",
        disposition: "held",
        seq: 2
      })

      dst =
        Repo.insert!(%Group{
          group_id: "old-dst",
          guest_id: "guest-22",
          property_id: "p-2",
          booked_on: ~D[2026-10-03],
          arrival_on: ~D[2026-12-10],
          departure_on: ~D[2026-12-13],
          rate_plan: "flexible",
          status: "active",
          revision: 2,
          policy_version: "flex-14",
          lodging_total_cents: 150_000,
          deposit_due_cents: 30_000,
          deposit_paid_cents: 4_000,
          cash_paid_cents: 4_000
        })

      rd =
        Repo.insert!(%Room{
          room_id: "room-c",
          nightly_rate_cents: 20_000,
          position: 0,
          status: "active",
          deposit_due_cents: 12_000,
          group_id: dst.id
        })

      Repo.insert!(%Room{
        room_id: "room-d",
        nightly_rate_cents: 30_000,
        position: 1,
        status: "active",
        deposit_due_cents: 18_000,
        group_id: dst.id
      })

      Repo.insert!(%RoomAllocation{
        group_id: dst.id,
        room_id: rd.id,
        kind: "cash",
        amount_cents: 4_000,
        payment_operation_id: "pay-other",
        disposition: "held",
        seq: 1
      })

      Repo.insert!(%OperationRecord{
        operation_id: "pay-old",
        type: "record_cash_payment",
        payload: "{}",
        result:
          Jason.encode!(%{
            "operation_id" => "pay-old",
            "status" => "applied",
            "group_id" => "old-src",
            "amount_cents" => 15_000,
            "outstanding_deposit_cents" => 4_500,
            "revision" => 2
          })
      })

      # Rows created by this release receive globally increasing seq values
      # above every legacy value.
      assert Repo.aggregate(from(a in RoomAllocation), :max, :seq) == 2

      {body, 200} =
        post_ops([
          transfer_deposit_op(%{
            "operation_id" => "op-9001",
            "source_group_id" => "old-src",
            "destination_group_id" => "old-dst",
            "amount_cents" => 4_000
          }),
          reduce_cash_payment_op(%{
            "operation_id" => "op-7001",
            "payment_operation_id" => "pay-old",
            "amount_cents" => 12_000
          })
        ])

      assert result(body, 0)["status"] == "applied"
      assert result(body, 0)["source_revision"] == 3
      assert result(body, 0)["destination_revision"] == 3

      assert result(body, 1)["revision"] == 4

      # The reduction drained the transferred slice in old-dst first, then
      # old-src in reverse fill order.
      source = get_group("old-src")

      assert Enum.map(source["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) == [
               {"room-a", 3_000},
               {"room-b", 0}
             ]

      destination = get_group("old-dst")

      assert Enum.map(destination["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) == [
               {"room-c", 4_000},
               {"room-d", 0}
             ]

      assert destination["revision"] == 4
      assert source["revision"] == 4

      {body, 200} = get_payment("pay-old")
      assert body["data"]["held_cents"] == 3_000
      assert body["data"]["reduced_cents"] == 12_000

      assert body["data"]["held_by_group"] == [
               %{"group_id" => "old-src", "amount_cents" => 3_000}
             ]
    end
  end

  describe "legacy funding" do
    test "unattributed funding can be moved and keeps no payment identity" do
      group =
        Repo.insert!(%Group{
          group_id: "legacy-src",
          guest_id: "guest-22",
          property_id: "p-1",
          booked_on: ~D[2026-06-05],
          arrival_on: ~D[2026-12-10],
          departure_on: ~D[2026-12-13],
          rate_plan: "flexible",
          status: "active",
          revision: 1,
          policy_version: nil,
          lodging_total_cents: 60_000,
          deposit_due_cents: 12_000,
          deposit_paid_cents: 8_000,
          cash_paid_cents: 8_000
        })

      Repo.insert!(%Room{
        room_id: "room-a",
        nightly_rate_cents: 15_000,
        position: 0,
        group_id: group.id
      })

      Repo.insert!(%Room{
        room_id: "room-b",
        nightly_rate_cents: 5_000,
        position: 1,
        group_id: group.id
      })

      RoomAccounting.backfill()

      {_, 200} = post_ops([destination_op()])

      {body, 200} =
        post_ops([
          transfer_deposit_op(%{
            "operation_id" => "op-9001",
            "source_group_id" => "legacy-src",
            "amount_cents" => 3_000
          })
        ])

      assert result(body)["status"] == "applied"
      assert result(body)["source_revision"] == 2

      source = get_group("legacy-src")

      assert Enum.map(source["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) == [
               {"room-a", 5_000},
               {"room-b", 0}
             ]

      destination = get_group("group-92")

      assert Enum.map(destination["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) == [
               {"room-x", 3_000},
               {"room-y", 0}
             ]
    end
  end
end
