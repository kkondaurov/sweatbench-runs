defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  defp open(id \\ "group", rates \\ [500, 500, 500]) do
    %{
      "operation_id" => "open-#{id}",
      "type" => "open_group",
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => "hotel",
      "occurred_on" => "2027-01-01",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" =>
        Enum.with_index(rates, fn rate, index ->
          %{"room_id" => "r#{index}", "nightly_rate_cents" => rate}
        end)
    }
  end

  defp op(id, type, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => type,
        "group_id" => "group",
        "occurred_on" => "2027-01-02"
      },
      attrs
    )
  end

  defp pay(id, amount, group \\ "group"),
    do: op(id, "record_cash_payment", %{"group_id" => group, "amount_cents" => amount})

  defp reduce(id, target, amount, attrs \\ %{}),
    do:
      op(
        id,
        "reduce_cash_payment",
        Map.merge(%{"payment_operation_id" => target, "amount_cents" => amount}, attrs)
      )
      |> Map.delete("group_id")

  defp charge(id, target, attrs \\ %{}),
    do:
      op(id, "charge_back_payment", Map.put(attrs, "payment_operation_id", target))
      |> Map.delete("group_id")

  defp cancel(id, rooms, attrs \\ %{}),
    do: op(id, "cancel_rooms", Map.put(attrs, "room_ids", rooms))

  defp batch(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{"operations" => ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp data(path),
    do: build_conn() |> get("/api/v1/#{path}") |> json_response(200) |> Map.fetch!("data")

  defp group(id \\ "group"), do: data("groups/#{id}")
  defp ledger(on \\ "2027-01-02"), do: data("ledger?on=#{on}")
  defp statement(id), do: data("payments/#{id}")
  defp credit(on \\ "2027-01-02"), do: data("guests/guest/credit?on=#{on}")

  defp paid_rooms(id \\ "group"),
    do: Enum.map(group(id)["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]})

  defp assert_conserved(ids) do
    statements = Enum.map(ids, &statement/1)

    for s <- statements do
      assert s["recorded_cents"] ==
               Enum.sum(
                 for key <-
                       ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
                     do: s[key]
               )

      assert map_size(s) == 9
    end

    for key <-
          ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents) do
      assert ledger()["cash_#{key}"] == Enum.sum(Enum.map(statements, & &1[key]))
    end
  end

  test "funding order, reverse reductions, partial cancellations and original payment replay" do
    payment = pay("p1", 150)
    [_, original, _] = batch([open(), payment, pay("p2", 100)])
    assert paid_rooms() == [{100, 0}, {100, 0}, {50, 0}]

    assert [%{"revision" => 4, "outstanding_deposit_cents" => 110}] =
             batch([reduce("reduce", "p1", 60)])

    assert paid_rooms() == [{90, 0}, {50, 0}, {50, 0}]
    assert statement("p1")["reduced_cents"] == 60
    batch([pay("p3", 30)])
    assert paid_rooms() == [{100, 0}, {70, 0}, {50, 0}]
    cancellation = cancel("partial", ["r2", "r0"])

    assert [%{"cancelled_room_ids" => ["r0", "r2"], "refunded_cents" => 150, "revision" => 6}] =
             batch([cancellation])

    assert group()["status"] == "active"
    assert group()["lodging_total_cents"] == 500
    assert group()["deposit_due_cents"] == 100
    assert group()["outstanding_deposit_cents"] == 30
    assert paid_rooms() == [{0, 0}, {70, 0}, {0, 0}]
    before = {group(), ledger(), statement("p1")}
    assert batch([payment]) == [original]
    assert batch([cancellation]) |> hd() |> Map.fetch!("revision") == 6
    assert {group(), ledger(), statement("p1")} == before
    assert [%{"code" => "payment_not_reducible"}] = batch([reduce("settled", "p1", 1)])
    assert [%{"refunded_cents" => 70, "revision" => 7}] = batch([op("remaining", "cancel_group")])
    assert group()["status"] == "cancelled"
    assert group()["lodging_total_cents"] == 0
    assert_conserved(["p1", "p2", "p3"])
  end

  test "room selection is atomic and revision precedes validation" do
    batch([open(), pay("p", 150)])

    for {ids, index} <-
          Enum.with_index([[], ["missing"], ["r0", "r0"], ["r0", "missing"], nil, "r0", [1]]) do
      before = {group(), ledger()}
      assert [%{"code" => "invalid_rooms"}] = batch([cancel("bad-#{index}", ids)])
      assert {group(), ledger()} == before
    end

    assert [%{"code" => "stale_revision", "actual_revision" => 2}] =
             batch([cancel("stale", [], %{"expected_revision" => 1})])

    batch([cancel("valid", ["r0"])])
    assert [%{"code" => "invalid_rooms"}] = batch([cancel("again", ["r0", "r1"])])
    assert group()["revision"] == 3
  end

  test "reduction errors, composition, exact retry and conflict" do
    batch([open(), pay("p", 150)])

    for {target, amount, code} <- [
          {"missing", 1, "operation_not_found"},
          {"open-group", 1, "payment_not_reducible"},
          {"p", 151, "reduction_exceeds_held_cash"},
          {"p", 0, "invalid_amount"},
          {"p", -1, "invalid_amount"},
          {"p", 1.5, "invalid_amount"},
          {"p", "1", "invalid_amount"}
        ] do
      assert [%{"code" => ^code}] =
               batch([reduce("bad-#{target}-#{inspect(amount)}", target, amount)])
    end

    assert [%{"code" => "stale_revision"}] =
             batch([reduce("stale", "p", -1, %{"expected_revision" => 1})])

    reduction = reduce("first", "p", 50, %{"expected_revision" => 2})
    [result] = batch([reduction])
    assert result["revision"] == 3
    assert batch([reduction]) == [result]

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(reduction, "amount_cents", 60)])

    assert [%{"revision" => 4}] = batch([reduce("rest", "p", 100)])
    assert [%{"code" => "payment_not_reducible"}] = batch([reduce("exhausted", "p", 1)])
    assert [%{"code" => "payment_not_chargeable"}] = batch([charge("cb", "p")])
    assert group()["outstanding_deposit_cents"] == 300
    assert_conserved(["p"])
  end

  test "chargeback reclassifies held, refunded, retained and converted cash while preserving reductions" do
    batch([
      open("group", [500, 500, 500, 500, 500]),
      pay("p", 500),
      cancel("refund", ["r0"]),
      cancel("retain", ["r1"], %{"occurred_on" => "2027-05-31"}),
      cancel("convert", ["r2"], %{"refund_method" => "hotel_credit"}),
      reduce("reduce", "p", 50)
    ])

    assert statement("p") == %{
             "payment_operation_id" => "p",
             "original_group_id" => "group",
             "recorded_cents" => 500,
             "held_cents" => 150,
             "refunded_cents" => 100,
             "retained_cents" => 100,
             "converted_to_credit_cents" => 100,
             "reduced_cents" => 50,
             "charged_back_cents" => 0
           }

    cb = charge("cb", "p", %{"expected_revision" => 6})
    [result] = batch([cb])
    assert result["charged_back_cents"] == 450
    assert result["outstanding_deposit_cents"] == 200
    assert result["revision"] == 7
    assert credit()["available_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert statement("p")["charged_back_cents"] == 450
    assert batch([cb]) == [result]
    assert [%{"code" => "payment_not_chargeable"}] = batch([charge("twice", "p")])
    assert_conserved(["p"])
  end

  test "combined bonus and per-payment running entitlements telescope independently per lot" do
    # Four cents from the first payment earn four credit cents. The next cent
    # crosses the half-cent threshold, so the second payment earns two.
    batch([open("group", [20, 5, 20, 5]), pay("p1", 4), pay("p2", 1), pay("p3", 4), pay("p4", 1)])

    assert [%{"credit_issued_cents" => 6}] =
             batch([cancel("lot1", ["r1", "r0"], %{"refund_method" => "hotel_credit"})])

    assert [%{"credit_issued_cents" => 6}] =
             batch([cancel("lot2", ["r3", "r2"], %{"refund_method" => "hotel_credit"})])

    assert credit()["available_cents"] == 12
    batch([charge("cb2", "p2")])
    assert credit()["available_cents"] == 10
    batch([charge("cb3", "p3")])
    assert credit()["available_cents"] == 6
    assert group()["status"] == "cancelled"
    batch([charge("cb1", "p1"), charge("cb4", "p4")])
    assert credit()["available_cents"] == 0
    assert_conserved(["p1", "p2", "p3", "p4"])
  end

  test "fungible credit shortfall is absorbed on restoration without changing funded groups" do
    batch([
      open("source", [1000]),
      pay("p1", 100, "source"),
      pay("p2", 100, "source"),
      op("issue", "cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open(),
      op("redeem", "apply_hotel_credit", %{"amount_cents" => 150})
    ])

    before = group()
    batch([charge("cb1", "p1")])
    assert group() == before
    assert credit()["available_cents"] == 0
    assert ledger()["credit_shortfall_cents"] == 40
    assert ledger()["credit_liability_cents"] == 150
    batch([cancel("restore", ["r1"])])
    assert credit()["available_cents"] == 10
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 110
    batch([charge("cb2", "p2")])
    assert ledger()["credit_shortfall_cents"] == 100
    batch([cancel("consume", ["r0"], %{"occurred_on" => "2027-05-31"})])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert_conserved(["p1", "p2"])
  end

  test "expired restoration absorbs clawback before discarding the excess" do
    batch([
      open("source", [500]),
      pay("p", 100, "source"),
      op("issue", "cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open(),
      op("redeem", "apply_hotel_credit", %{"amount_cents" => 110}),
      charge("cb", "p"),
      op("move", "reschedule_group", %{"new_arrival_on" => "2029-06-01"})
    ])

    assert ledger("2028-01-03")["credit_shortfall_cents"] == 110
    batch([cancel("restore-expired", ["r0"], %{"occurred_on" => "2028-01-03"})])
    assert ledger("2028-01-03")["credit_shortfall_cents"] == 10
    assert ledger("2028-01-03")["credit_liability_cents"] == 10
    lot = GroupStay.Repo.one!(GroupStay.Credits.Lot)
    assert lot.unrecovered_clawback_cents == 10
    assert lot.remaining_cents == 0
    batch([op("rest", "cancel_group", %{"occurred_on" => "2028-01-03"})])
    assert ledger("2028-01-03")["credit_liability_cents"] == 0
    assert GroupStay.Repo.one!(GroupStay.Credits.Lot).unrecovered_clawback_cents == 0
  end

  test "cash and multiple credit lots fill vacancies in processing order" do
    batch([
      open("source1"),
      pay("p1", 100, "source1"),
      op("issue1", "cancel_group", %{"group_id" => "source1", "refund_method" => "hotel_credit"}),
      open("source2"),
      pay("p2", 100, "source2"),
      op("issue2", "cancel_group", %{"group_id" => "source2", "refund_method" => "hotel_credit"}),
      open(),
      pay("p3", 50),
      op("credit", "apply_hotel_credit", %{"amount_cents" => 170}),
      pay("p4", 30)
    ])

    assert paid_rooms() == [{50, 50}, {0, 100}, {30, 20}]
    batch([cancel("return", ["r1"])])

    assert credit()["lots"] == [
             %{
               "source_operation_id" => "issue1",
               "remaining_cents" => 60,
               "expires_on" => "2028-01-02"
             },
             %{
               "source_operation_id" => "issue2",
               "remaining_cents" => 90,
               "expires_on" => "2028-01-02"
             }
           ]

    assert paid_rooms() == [{50, 50}, {0, 0}, {30, 20}]
    assert_conserved(["p1", "p2", "p3", "p4"])
  end

  test "one payment contributes to several lots and shortfall is capped by active credit" do
    batch([
      open("source", [25, 25]),
      pay("p", 10, "source"),
      cancel("lot1", ["r0"], %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      cancel("lot2", ["r1"], %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open("group", [25, 25]),
      op("redeem", "apply_hotel_credit", %{"amount_cents" => 10}),
      cancel("consume", ["r0"], %{"occurred_on" => "2027-05-31"})
    ])

    assert credit()["available_cents"] == 2
    assert ledger()["credit_liability_cents"] == 7
    assert [%{"charged_back_cents" => 10}] = batch([charge("cb", "p")])
    assert credit()["available_cents"] == 0
    assert ledger()["credit_shortfall_cents"] == 5
    assert ledger()["credit_liability_cents"] == 5
    batch([cancel("return", ["r1"])])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert_conserved(["p"])
  end

  test "chargeback stale results remain exact after later settlement" do
    batch([open(), pay("p", 100)])
    stale = charge("stale", "p", %{"expected_revision" => 1})
    assert [%{"code" => "stale_revision", "actual_revision" => 2} = original] = batch([stale])
    batch([op("cancel", "cancel_group")])
    assert batch([stale]) == [original]

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(stale, "expected_revision", 3)])

    assert [%{"revision" => 4, "charged_back_cents" => 100}] =
             batch([charge("valid", "p", %{"expected_revision" => 3})])

    assert [%{"code" => "stale_revision"}] =
             batch([charge("stale-again", "p", %{"expected_revision" => 3})])

    assert group()["revision"] == 4
  end

  @tag :capture_log
  test "a journal failure rolls back chargeback dispositions, clawback and revisions" do
    batch([
      open("source"),
      pay("p", 100, "source"),
      op("issue", "cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open(),
      op("redeem", "apply_hotel_credit", %{"amount_cents" => 100})
    ])

    before = {group("source"), group(), statement("p"), ledger(), credit()}

    GroupStay.Repo.query!("""
    CREATE TRIGGER reject_chargeback_journal BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected journal failure'); END
    """)

    operation = charge("fault", "p")
    assert_error_sent 500, fn -> batch([operation, pay("later", 1)]) end
    assert {group("source"), group(), statement("p"), ledger(), credit()} == before
    assert GroupStay.Operations.get_result("fault") == nil
    assert GroupStay.Operations.get_result("later") == nil
    GroupStay.Repo.query!("DROP TRIGGER reject_chargeback_journal")
    assert [%{"charged_back_cents" => 100}] = batch([operation])
    assert ledger()["credit_shortfall_cents"] == 100
  end

  test "payment lookup distinguishes missing, rejected and unrelated operations without writes" do
    batch([open(), pay("rejected", 999)])

    assert build_conn() |> get("/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    for target <- ["rejected", "open-group"] do
      assert build_conn() |> get("/api/v1/payments/#{target}") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }

      assert [%{"code" => "payment_not_chargeable"}] = batch([charge("cb-#{target}", target)])

      assert [%{"code" => "payment_not_reducible"}] =
               batch([reduce("reduce-#{target}", target, 1)])
    end

    assert [%{"code" => "operation_not_found"}] = batch([charge("missing", "missing")])
    assert group()["revision"] == 1
  end
end
