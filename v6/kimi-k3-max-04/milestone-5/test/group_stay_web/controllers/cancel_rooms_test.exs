defmodule GroupStayWeb.CancelRoomsTest do
  @moduledoc """
  Room-level accounting and the `cancel_rooms` operation
  (docs/requests/04-room-accounting-and-payment-reductions.md).
  """
  use GroupStayWeb.ConnCase, async: false

  # Helpers -----------------------------------------------------------------

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group_view(conn, group_id) do
    conn
    |> get(~p"/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn
    |> get(~p"/api/v1/ledger")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp guest_credit(conn, guest_id) do
    conn
    |> get(~p"/api/v1/guests/#{guest_id}/credit")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  # Two rooms, three nights: room-a due 9000, room-b due 10500 (total 19500).
  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp payment_op(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "record_cash_payment",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp cancel_rooms_op(group_id, room_ids, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-26",
        "group_id" => group_id,
        "room_ids" => room_ids
      },
      overrides
    )
  end

  defp next_id, do: "op-#{System.unique_integer([:positive])}"
  defp uniq(suffix), do: "group-#{suffix}-#{System.unique_integer([:positive])}"

  # Room-level accounting -----------------------------------------------------

  describe "room-level accounting" do
    test "rooms expose status and per-room deposit and paid amounts", %{conn: conn} do
      group_id = uniq("rooms")
      submit(conn, [open_op(group_id), payment_op(group_id, 10_000)])

      data = group_view(conn, group_id)

      assert %{
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "nightly_rate_cents" => 15000,
                   "status" => "active",
                   "deposit_due_cents" => 9000,
                   "cash_paid_cents" => 9000,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "nightly_rate_cents" => 17500,
                   "status" => "active",
                   "deposit_due_cents" => 10500,
                   "cash_paid_cents" => 1000,
                   "credit_paid_cents" => 0
                 }
               ],
               "deposit_paid_cents" => 10_000,
               "cash_paid_cents" => 10_000,
               "outstanding_deposit_cents" => 9500
             } = data
    end

    test "funding fills one room's deposit before moving to the next", %{conn: conn} do
      group_id = uniq("fill")

      submit(conn, [
        open_op(group_id),
        payment_op(group_id, 9000),
        payment_op(group_id, 10500)
      ])

      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 10500}
               ],
               "outstanding_deposit_cents" => 0
             } = group_view(conn, group_id)
    end

    test "credit also funds rooms in their original order", %{conn: conn} do
      group_id = uniq("credit-fill")

      # Issue the guest a credit lot from an earlier refundable cancellation.
      submit(conn, [
        open_op("group-donor", %{
          "group_id" => "group-donor",
          "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 10000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        }),
        payment_op("group-donor", 2000),
        %{
          "operation_id" => next_id(),
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-donor",
          "refund_method" => "hotel_credit"
        }
      ])

      [applied] =
        submit(conn, [
          open_op(group_id),
          %{
            "operation_id" => next_id(),
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-11-27",
            "group_id" => group_id,
            "amount_cents" => 2200
          }
        ])
        |> Enum.drop(1)

      assert %{"status" => "applied"} = applied

      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "credit_paid_cents" => 2200},
                 %{"room_id" => "room-b", "credit_paid_cents" => 0}
               ],
               "credit_paid_cents" => 2200
             } = group_view(conn, group_id)
    end
  end

  # cancel_rooms ----------------------------------------------------------------

  describe "cancel_rooms" do
    test "settles the selected rooms and leaves the others untouched", %{conn: conn} do
      group_id = uniq("settle")

      [_, _, cancelled] =
        submit(conn, [
          open_op(group_id),
          payment_op(group_id, 19_500),
          cancel_rooms_op(group_id, ["room-b"])
        ])

      assert %{
               "status" => "applied",
               "group_id" => ^group_id,
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 10_500,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             } = cancelled

      assert %{
               "status" => "active",
               "lodging_total_cents" => 45_000,
               "deposit_due_cents" => 9000,
               "deposit_paid_cents" => 9000,
               "outstanding_deposit_cents" => 0,
               "rooms" => [
                 %{"room_id" => "room-a", "status" => "active", "cash_paid_cents" => 9000},
                 %{
                   "room_id" => "room-b",
                   "status" => "cancelled",
                   "deposit_due_cents" => 10500,
                   "cash_paid_cents" => 0
                 }
               ]
             } = group_view(conn, group_id)

      assert %{"cash_held_cents" => 9000, "cash_refunded_cents" => 10_500} = ledger(conn)
    end

    test "unpaid deposit for cancelled rooms simply ceases to be due", %{conn: conn} do
      group_id = uniq("unpaid")

      [cancelled] =
        submit(conn, [
          open_op(group_id),
          payment_op(group_id, 9000),
          cancel_rooms_op(group_id, ["room-b"])
        ])
        |> Enum.drop(2)

      assert %{"status" => "applied", "refunded_cents" => 0} = cancelled

      assert %{
               "deposit_due_cents" => 9000,
               "outstanding_deposit_cents" => 0,
               "status" => "active",
               "rooms" => [
                 %{"room_id" => "room-a", "status" => "active"},
                 %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 0}
               ]
             } = group_view(conn, group_id)
    end

    test "reports cancelled rooms in the group's original room order", %{conn: conn} do
      group_id = uniq("order")

      open =
        open_op(group_id, %{
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 10000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 10000},
            %{"room_id" => "room-c", "nightly_rate_cents" => 10000}
          ]
        })

      [cancelled] =
        submit(conn, [open, cancel_rooms_op(group_id, ["room-c", "room-a"])])
        |> Enum.drop(1)

      assert %{"status" => "applied", "cancelled_room_ids" => ["room-a", "room-c"]} = cancelled
    end

    test "retains cash on non-refundable settlement", %{conn: conn} do
      group_id = uniq("retain")

      [cancelled] =
        submit(conn, [
          open_op(group_id),
          payment_op(group_id, 19_500),
          cancel_rooms_op(group_id, ["room-a"], %{"occurred_on" => "2026-11-27"})
        ])
        |> Enum.drop(2)

      assert %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 9000} = cancelled
      assert %{"cash_retained_cents" => 9000, "cash_held_cents" => 10_500} = ledger(conn)
    end

    test "issues one credit lot with the bonus computed on the combined cash", %{conn: conn} do
      group_id = uniq("bonus")

      # One-night rooms with deposits 3335 + 3335 = 6670. A per-room bonus
      # would round 333.5 up twice (7338); the combined bonus rounds once.
      open =
        open_op(group_id, %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 16675},
            %{"room_id" => "room-b", "nightly_rate_cents" => 16675},
            %{"room_id" => "room-c", "nightly_rate_cents" => 1000}
          ]
        })

      [cancelled] =
        submit(conn, [
          open,
          payment_op(group_id, 6870),
          cancel_rooms_op(group_id, ["room-a", "room-b"], %{"refund_method" => "hotel_credit"})
        ])
        |> Enum.drop(2)

      assert %{
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 7337
             } = cancelled

      assert %{
               "available_cents" => 7337,
               "lots" => [%{"remaining_cents" => 7337, "expires_on" => "2027-11-26"}]
             } = guest_credit(conn, "guest-22")

      assert %{"cash_converted_to_credit_cents" => 6670} = ledger(conn)
    end

    test "rejects hotel credit for a non-refundable settlement", %{conn: conn} do
      group_id = uniq("credit-denied")

      [cancelled] =
        submit(conn, [
          open_op(group_id),
          payment_op(group_id, 9000),
          cancel_rooms_op(group_id, ["room-a"], %{
            "occurred_on" => "2026-11-27",
            "refund_method" => "hotel_credit"
          })
        ])
        |> Enum.drop(2)

      assert %{"status" => "rejected", "code" => "refund_method_not_available"} = cancelled

      assert %{"status" => "active", "deposit_paid_cents" => 9000} = group_view(conn, group_id)
    end

    test "restores applied credit from the selected rooms only", %{conn: conn} do
      group_id = uniq("restore")

      submit(conn, [
        open_op("group-donor-2", %{
          "group_id" => "group-donor-2",
          "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 10000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        }),
        payment_op("group-donor-2", 2000),
        %{
          "operation_id" => next_id(),
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-donor-2",
          "refund_method" => "hotel_credit"
        }
      ])

      # The 2200 lot fills the rest of room-a after the cash payment.
      submit(conn, [
        open_op(group_id),
        payment_op(group_id, 6800),
        %{
          "operation_id" => next_id(),
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-27",
          "group_id" => group_id,
          "amount_cents" => 2200
        }
      ])

      [cancelled] = submit(conn, [cancel_rooms_op(group_id, ["room-a"])])

      assert %{"status" => "applied", "refunded_cents" => 6800} = cancelled

      # room-a held 2200 credit + 6800 cash; the credit returns to its lot.
      assert %{"available_cents" => 2200} = guest_credit(conn, "guest-22")

      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "status" => "cancelled"},
                 %{"room_id" => "room-b", "status" => "active", "cash_paid_cents" => 0}
               ],
               "outstanding_deposit_cents" => 10500
             } = group_view(conn, group_id)
    end

    test "rejects unknown, duplicate, or already-cancelled rooms atomically", %{conn: conn} do
      group_id = uniq("invalid")
      submit(conn, [open_op(group_id), payment_op(group_id, 19_500)])

      for room_ids <- [["room-z"], ["room-a", "room-a"], ["room-a", "room-z"], []] do
        [result] = submit(conn, [cancel_rooms_op(group_id, room_ids)])
        assert %{"status" => "rejected", "code" => "invalid_rooms"} = result
      end

      # Settle room-a, then try to settle it again.
      submit(conn, [cancel_rooms_op(group_id, ["room-a"])])
      [again] = submit(conn, [cancel_rooms_op(group_id, ["room-a"])])
      assert %{"status" => "rejected", "code" => "invalid_rooms"} = again

      # Nothing but the legitimate settlement changed the group.
      assert %{
               "revision" => 3,
               "rooms" => [
                 %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 0},
                 %{"room_id" => "room-b", "status" => "active", "cash_paid_cents" => 10500}
               ]
             } = group_view(conn, group_id)
    end

    test "rejects missing groups, missing room ids, and bad refund methods", %{conn: conn} do
      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               submit(conn, [cancel_rooms_op("group-nope", ["room-a"])])

      group_id = uniq("missing-data")
      submit(conn, [open_op(group_id)])

      no_rooms = cancel_rooms_op(group_id, ["room-a"]) |> Map.delete("room_ids")
      assert [%{"status" => "rejected", "code" => "invalid_operation"}] = submit(conn, [no_rooms])

      bad_method = cancel_rooms_op(group_id, ["room-a"], %{"refund_method" => "voucher"})

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               submit(conn, [bad_method])

      not_a_list = cancel_rooms_op(group_id, "room-a")

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               submit(conn, [not_a_list])
    end

    test "cancelling the last active rooms cancels the group", %{conn: conn} do
      group_id = uniq("all-rooms")

      [cancelled] =
        submit(conn, [
          open_op(group_id),
          payment_op(group_id, 19_500),
          cancel_rooms_op(group_id, ["room-a", "room-b"])
        ])
        |> Enum.drop(2)

      assert %{"status" => "applied", "refunded_cents" => 19_500} = cancelled
      assert %{"status" => "cancelled"} = group_view(conn, group_id)

      assert [%{"status" => "rejected", "code" => "group_not_active"}] =
               submit(conn, [cancel_rooms_op(group_id, ["room-a"])])
    end

    test "cancel_group settles only the remaining active rooms", %{conn: conn} do
      group_id = uniq("remaining")

      [_, _, _, cancelled] =
        submit(conn, [
          open_op(group_id),
          payment_op(group_id, 19_500),
          cancel_rooms_op(group_id, ["room-a"]),
          %{
            "operation_id" => next_id(),
            "type" => "cancel_group",
            "occurred_on" => "2026-11-26",
            "group_id" => group_id
          }
        ])

      # The classic contract is unchanged and only room-b's cash settles.
      assert %{
               "status" => "applied",
               "group_id" => ^group_id,
               "refunded_cents" => 10_500,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             } = cancelled

      refute Map.has_key?(cancelled, "cancelled_room_ids")
      assert %{"status" => "cancelled", "deposit_paid_cents" => 0} = group_view(conn, group_id)
    end

    test "follows the expected_revision contract", %{conn: conn} do
      group_id = uniq("revision")
      submit(conn, [open_op(group_id), payment_op(group_id, 19_500)])

      [stale] =
        submit(conn, [cancel_rooms_op(group_id, ["room-a"], %{"expected_revision" => 1})])

      assert %{
               "status" => "rejected",
               "code" => "stale_revision",
               "expected_revision" => 1,
               "actual_revision" => 2
             } = stale

      [ok] = submit(conn, [cancel_rooms_op(group_id, ["room-a"], %{"expected_revision" => 2})])
      assert %{"status" => "applied", "revision" => 3} = ok
    end

    test "is durably idempotent", %{conn: conn} do
      group_id = uniq("idempotent")
      submit(conn, [open_op(group_id), payment_op(group_id, 19_500)])

      op = cancel_rooms_op(group_id, ["room-b"])
      [first] = submit(conn, [op])
      [retry] = submit(conn, [op])

      assert retry == first
      assert %{"status" => "applied", "revision" => 3} = first

      # The settlement happened exactly once.
      assert %{"revision" => 3, "cash_paid_cents" => 9000} = group_view(conn, group_id)
      assert %{"cash_refunded_cents" => 10_500} = ledger(conn)
    end
  end
end
