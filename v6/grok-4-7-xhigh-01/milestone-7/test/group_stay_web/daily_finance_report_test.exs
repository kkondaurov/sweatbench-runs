defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Credits
  alias GroupStay.Credits.Lot
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "start_finance_reporting" do
    test "enables reporting and returns only the inception fields", %{conn: conn} do
      {conn, result} = one(conn, start_op("2026-10-01"))

      assert result == %{
               "operation_id" => "start-2026-10-01",
               "status" => "applied",
               "starts_on" => "2026-10-01"
             }

      assert json_response(get(conn, "/api/v1/operations/start-2026-10-01"), 200)["data"] ==
               result

      assert report(conn, "2026-10-01") == empty_report("2026-10-01")
    end

    test "rejects a missing, blank, or invalid starts_on", %{conn: conn} do
      {conn, missing} =
        one(
          conn,
          Map.delete(start_op("2026-10-01"), "starts_on") |> Map.put("operation_id", "s1")
        )

      {conn, blank} =
        one(conn, start_op("2026-10-01", %{"operation_id" => "s2", "starts_on" => ""}))

      {conn, bad} =
        one(conn, start_op("2026-10-01", %{"operation_id" => "s3", "starts_on" => "2026-13-40"}))

      {conn, integer} =
        one(conn, start_op("2026-10-01", %{"operation_id" => "s4", "starts_on" => 20_261_001}))

      assert missing["code"] == "invalid_reporting_date"
      assert blank["code"] == "invalid_reporting_date"
      assert bad["code"] == "invalid_reporting_date"
      assert integer["code"] == "invalid_reporting_date"
      assert report_error(conn, "2026-10-01", 404)["error"]["code"] == "report_not_available"
    end

    test "does not require a group or revision and ignores a stale revision", %{conn: conn} do
      {_conn, result} =
        one(
          conn,
          start_op("2026-10-08", %{
            "group_id" => "missing",
            "expected_revision" => 4,
            "destination_expected_revision" => 9
          })
        )

      assert result["status"] == "applied"
      assert result["starts_on"] == "2026-10-08"
      refute Map.has_key?(result, "revision")
      refute Map.has_key?(result, "group_id")
    end

    test "rejects a second inception and replays the original exactly", %{conn: conn} do
      {conn, first} = one(conn, start_op("2026-10-01"))
      before = report(conn, "2026-10-01")

      {conn, again} = one(conn, start_op("2026-10-01"))
      assert again == first
      assert report(conn, "2026-10-01") == before

      {conn, other_date} =
        one(conn, start_op("2026-11-01", %{"operation_id" => "start-other"}))

      assert other_date["status"] == "rejected"
      assert other_date["code"] == "reporting_already_started"

      {conn, conflict} =
        one(conn, start_op("2026-12-01", %{"operation_id" => "start-2026-10-01"}))

      assert conflict["code"] == "operation_id_conflict"
      assert report(conn, "2026-10-01") == before
      assert report_error(conn, "2026-09-30", 404)["error"]["code"] == "report_not_available"
    end

    test "a rejected start leaves reporting disabled and can be retried as stored", %{
      conn: conn
    } do
      {conn, rejected} =
        one(conn, start_op("nope", %{"operation_id" => "bad-start", "starts_on" => "nope"}))

      {conn, replay} =
        one(conn, start_op("nope", %{"operation_id" => "bad-start", "starts_on" => "nope"}))

      assert replay == rejected
      assert report_error(conn, "2026-10-01", 404)["error"]["code"] == "report_not_available"

      {conn, _} = one(conn, start_op("2026-10-01", %{"operation_id" => "good-start"}))
      assert report(conn, "2026-10-01")["status"] == "open"
    end
  end

  describe "GET /api/v1/finance/daily-report" do
    test "rejects a missing or invalid date before checking availability", %{conn: conn} do
      assert report_error(conn, nil, 422)["error"]["code"] == "invalid_reporting_date"

      for date <- ["", "yesterday", "2026-02-30", "2026-10-1", "2026-10-01T00:00:00"] do
        assert report_error(conn, date, 422)["error"]["code"] == "invalid_reporting_date"
      end

      {conn, _} = one(conn, start_op("2026-10-01"))
      assert report_error(conn, "not-a-date", 422)["error"]["code"] == "invalid_reporting_date"
      assert report_error(conn, "2026-09-30", 404)["error"]["code"] == "report_not_available"
    end

    test "reading reports does not change domain state", %{conn: conn} do
      conn = fund(conn, "g", "ams-canal", 400, "pay")
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, _} =
        one(
          conn,
          payment_op("g", 100, %{"operation_id" => "later", "occurred_on" => "2026-10-03"})
        )

      before = snapshot(conn, "g")
      records = Repo.aggregate(Record, :count, :id)

      first = report(conn, "2026-10-03")
      second = report(conn, "2026-10-01")
      third = report(conn, "2026-10-03")

      assert first == third
      assert second["date"] == "2026-10-01"
      assert snapshot(conn, "g") == before
      assert Repo.aggregate(Record, :count, :id) == records
    end
  end

  describe "opening position and posting dates" do
    test "committed activity is opening even when occurred_on is on or after starts_on", %{
      conn: conn
    } do
      conn = fund(conn, "early", "ams-canal", 250, "early-pay", "2026-12-01")
      conn = fund(conn, "late", "bbb-dock", 150, "late-pay", "2026-09-01")
      {conn, _} = one(conn, start_op("2026-10-05"))

      report = report(conn, "2026-10-05")

      assert report["cash"] == [
               cash_entry("ams-canal", 250, %{}, 250),
               cash_entry("bbb-dock", 150, %{}, 150)
             ]

      assert report["credit"] == credit_entry(0, %{}, 0)
      assert report_error(conn, "2026-10-04", 404)["error"]["code"] == "report_not_available"
    end

    test "same-batch operations before the start are opening and later ones are movements", %{
      conn: conn
    } do
      conn = open_group(conn, "g", "ams-canal")

      {conn, results} =
        batch(conn, [
          payment_op("g", 400, %{"operation_id" => "before", "occurred_on" => "2026-12-20"}),
          start_op("2026-10-01", %{"operation_id" => "start-batch"}),
          payment_op("g", 100, %{"operation_id" => "after", "occurred_on" => "2026-09-15"})
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied"]

      assert report(conn, "2026-10-01")["cash"] == [
               cash_entry("ams-canal", 400, %{"received_cents" => 100}, 500)
             ]

      sequential = report(conn, "2026-10-02")
      assert sequential["cash"] == [cash_entry("ams-canal", 500, %{}, 500)]
    end

    test "a later submission posts on the later of occurred_on and starts_on", %{conn: conn} do
      conn = open_group(conn, "g", "ams-canal")
      {conn, _} = one(conn, start_op("2026-10-10"))
      before = report(conn, "2026-10-10")

      {conn, _} =
        one(conn, payment_op("g", 80, %{"operation_id" => "back", "occurred_on" => "2026-10-01"}))

      {conn, _} =
        one(
          conn,
          payment_op("g", 20, %{"operation_id" => "future", "occurred_on" => "2026-10-12"})
        )

      assert report(conn, "2026-10-10")["cash"] == [
               cash_entry("ams-canal", 0, %{"received_cents" => 80}, 80)
             ]

      assert report(conn, "2026-10-11")["cash"] == [cash_entry("ams-canal", 80, %{}, 80)]

      assert report(conn, "2026-10-12")["cash"] == [
               cash_entry("ams-canal", 80, %{"received_cents" => 20}, 100)
             ]

      refute before == report(conn, "2026-10-10")
    end

    test "equivalent batches post the same movements as one-at-a-time submissions", %{conn: conn} do
      conn = open_group(conn, "batch", "ams-canal")

      {conn, _} =
        batch(conn, [
          start_op("2026-10-01", %{"operation_id" => "start-eq"}),
          payment_op("batch", 40, %{"operation_id" => "p1", "occurred_on" => "2026-10-02"}),
          payment_op("batch", 60, %{"operation_id" => "p2", "occurred_on" => "2026-10-02"})
        ])

      assert report(conn, "2026-10-02")["cash"] == [
               cash_entry("ams-canal", 0, %{"received_cents" => 100}, 100)
             ]
    end
  end

  describe "cash movements" do
    test "classifies receipt, transfer, settlement, reduction, and chargeback by current property",
         %{conn: conn} do
      conn = open_group(conn, "src", "ams-canal")
      conn = open_group(conn, "dst", "ams-jordaan", %{"guest_id" => "guest-22"})
      conn = open_group(conn, "zzz", "zzz-quay")
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, _} =
        one(
          conn,
          payment_op("src", 1000, %{"operation_id" => "pay", "occurred_on" => "2026-10-02"})
        )

      {conn, _} =
        one(
          conn,
          transfer_op("src", "dst", 600, %{
            "operation_id" => "move",
            "occurred_on" => "2026-10-03"
          })
        )

      {conn, _} =
        one(
          conn,
          reduce_op("pay", 500, %{"operation_id" => "trim", "occurred_on" => "2026-10-04"})
        )

      {conn, _} =
        one(
          conn,
          cancel_op("dst", %{"operation_id" => "refund-dst", "occurred_on" => "2026-10-05"})
        )

      {conn, _} =
        one(conn, charge_op("pay", %{"operation_id" => "claw", "occurred_on" => "2026-10-06"}))

      assert report(conn, "2026-10-02")["cash"] == [
               cash_entry("ams-canal", 0, %{"received_cents" => 1000}, 1000)
             ]

      transfer = report(conn, "2026-10-03")

      assert transfer["cash"] == [
               cash_entry("ams-canal", 1000, %{"transferred_out_cents" => 600}, 400),
               cash_entry("ams-jordaan", 0, %{"transferred_in_cents" => 600}, 600)
             ]

      assert transferred_in(transfer) == transferred_out(transfer)

      reduced = report(conn, "2026-10-04")

      assert reduced["cash"] == [
               cash_entry("ams-canal", 400, %{}, 400),
               cash_entry("ams-jordaan", 600, %{"reduced_cents" => 500}, 100)
             ]

      assert report(conn, "2026-10-05")["cash"] == [
               cash_entry("ams-canal", 400, %{}, 400),
               cash_entry("ams-jordaan", 100, %{"refunded_cents" => 100}, 0)
             ]

      reversed = report(conn, "2026-10-06")

      assert reversed["cash"] == [
               cash_entry("ams-canal", 400, %{"charged_back_cents" => 400}, 0),
               cash_entry(
                 "ams-jordaan",
                 0,
                 %{"refunded_cents" => -100, "charged_back_cents" => 100},
                 0
               )
             ]

      assert ledger(conn)["data"]["cash_held_cents"] == 0
      assert ledger(conn)["data"]["cash_refunded_cents"] == 0
      assert ledger(conn)["data"]["cash_reduced_cents"] == 500
      assert ledger(conn)["data"]["cash_charged_back_cents"] == 500
      refute Enum.any?(reversed["cash"], &(&1["property_id"] == "zzz-quay"))
      assert report(conn, "2026-10-07")["cash"] == []
      assert_cash_identity(reversed)
    end

    test "retains and converts cash where it is held, not at the original property", %{conn: conn} do
      conn = open_group(conn, "src", "ams-canal")
      conn = open_group(conn, "keep", "ams-jordaan")
      conn = open_group(conn, "fee", "bbb-dock", %{"rate_plan" => "advance_purchase"})
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, _} =
        one(
          conn,
          payment_op("src", 900, %{"operation_id" => "pool", "occurred_on" => "2026-10-02"})
        )

      {conn, _} =
        one(
          conn,
          transfer_op("src", "keep", 400, %{
            "operation_id" => "to-keep",
            "occurred_on" => "2026-10-03"
          })
        )

      {conn, _} =
        one(
          conn,
          transfer_op("src", "fee", 300, %{
            "operation_id" => "to-fee",
            "occurred_on" => "2026-10-03"
          })
        )

      {conn, _} =
        one(
          conn,
          cancel_op("keep", %{
            "operation_id" => "to-credit",
            "occurred_on" => "2026-10-04",
            "refund_method" => "hotel_credit"
          })
        )

      {conn, _} =
        one(
          conn,
          cancel_op("fee", %{"operation_id" => "keep-fee", "occurred_on" => "2026-10-04"})
        )

      day = report(conn, "2026-10-04")

      assert Enum.find(day["cash"], &(&1["property_id"] == "ams-jordaan"))["movements"][
               "converted_to_credit_cents"
             ] == 400

      assert Enum.find(day["cash"], &(&1["property_id"] == "bbb-dock"))["movements"][
               "retained_cents"
             ] == 300

      assert Enum.find(day["cash"], &(&1["property_id"] == "ams-canal"))["movements"][
               "converted_to_credit_cents"
             ] == 0

      assert day["credit"]["movements"]["issued_cents"] == Credits.issued_amount(400)
      assert day["credit"]["closing_liability_cents"] == Credits.issued_amount(400)
      assert ledger(conn)["data"]["cash_converted_to_credit_cents"] == 400
      assert ledger(conn)["data"]["cash_retained_cents"] == 300
      assert ledger(conn)["data"]["credit_liability_cents"] == Credits.issued_amount(400)
    end

    test "a credit-only transfer does not move cash and same-property cash transfers net to zero",
         %{conn: conn} do
      conn = issue_credit(conn, "guest-22", 200)
      conn = open_group(conn, "src", "ams-canal")
      conn = open_group(conn, "dst", "ams-canal")
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, _} =
        one(
          conn,
          payment_op("src", 100, %{"operation_id" => "cash", "occurred_on" => "2026-10-02"})
        )

      {conn, _} =
        one(
          conn,
          credit_op("src", 200, %{"operation_id" => "park", "occurred_on" => "2026-10-02"})
        )

      before = ledger(conn)["data"]

      {conn, _} =
        one(
          conn,
          transfer_op("src", "dst", 200, %{
            "operation_id" => "credit-only",
            "occurred_on" => "2026-10-03"
          })
        )

      credit_only = report(conn, "2026-10-03")
      assert credit_only["cash"] == [cash_entry("ams-canal", 100, %{}, 100)]
      assert credit_only["credit"]["movements"] == zero_credit_movements()
      assert ledger(conn)["data"] == before

      {conn, _} =
        one(
          conn,
          transfer_op("src", "dst", 50, %{
            "operation_id" => "same-property",
            "occurred_on" => "2026-10-04"
          })
        )

      same = report(conn, "2026-10-04")
      [entry] = same["cash"]
      assert entry["property_id"] == "ams-canal"
      assert entry["movements"]["transferred_in_cents"] == 50
      assert entry["movements"]["transferred_out_cents"] == 50
      assert entry["closing_held_cents"] == entry["opening_held_cents"]
      assert transferred_in(same) == transferred_out(same)
    end

    test "charges back held and converted cash at the property where it currently sits", %{
      conn: conn
    } do
      conn = open_group(conn, "src", "ams-canal")
      conn = open_group(conn, "dst", "ams-jordaan")
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, _} =
        one(
          conn,
          payment_op("src", 800, %{"operation_id" => "pay", "occurred_on" => "2026-10-02"})
        )

      {conn, _} =
        one(
          conn,
          transfer_op("src", "dst", 500, %{
            "operation_id" => "move",
            "occurred_on" => "2026-10-03"
          })
        )

      {conn, _} =
        one(
          conn,
          cancel_op("dst", %{
            "operation_id" => "convert",
            "occurred_on" => "2026-10-04",
            "refund_method" => "hotel_credit"
          })
        )

      {conn, _} =
        one(conn, charge_op("pay", %{"operation_id" => "claw", "occurred_on" => "2026-10-05"}))

      day = report(conn, "2026-10-05")

      assert Enum.find(day["cash"], &(&1["property_id"] == "ams-canal"))["movements"] ==
               Map.merge(zero_cash_movements(), %{"charged_back_cents" => 300})

      jordaan = Enum.find(day["cash"], &(&1["property_id"] == "ams-jordaan"))

      assert jordaan["movements"]["converted_to_credit_cents"] == -500
      assert jordaan["movements"]["charged_back_cents"] == 500
      assert jordaan["closing_held_cents"] == 0
      assert day["credit"]["movements"]["revoked_cents"] == Credits.issued_amount(500)
      assert ledger(conn)["data"]["cash_charged_back_cents"] == 800
      assert ledger(conn)["data"]["cash_converted_to_credit_cents"] == 0
      assert ledger(conn)["data"]["credit_liability_cents"] == 0
    end

    test "rejected operations and durable retries do not post twice or at all", %{conn: conn} do
      conn = open_group(conn, "g", "ams-canal")
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, applied} =
        one(conn, payment_op("g", 40, %{"operation_id" => "once", "occurred_on" => "2026-10-02"}))

      {conn, replay} =
        one(conn, payment_op("g", 40, %{"operation_id" => "once", "occurred_on" => "2026-10-02"}))

      assert replay == applied

      {conn, results} =
        batch(conn, [
          payment_op("g", 10, %{"operation_id" => "kept", "occurred_on" => "2026-10-02"}),
          payment_op("g", 9_999, %{"operation_id" => "too-much", "occurred_on" => "2026-10-02"}),
          %{"operation_id" => "bad", "type" => "nope", "occurred_on" => "2026-10-02"}
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "rejected", "rejected"]
      assert results |> Enum.at(1) |> Map.get("code") == "payment_exceeds_outstanding"

      assert report(conn, "2026-10-02")["cash"] == [
               cash_entry("ams-canal", 0, %{"received_cents" => 50}, 50)
             ]
    end
  end

  describe "credit movements" do
    test "applying and restoring credit does not change liability", %{conn: conn} do
      conn = issue_credit(conn, "guest-22", 300)
      issued = Credits.issued_amount(300)
      conn = open_group(conn, "hold", "ams-canal")
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, _} =
        one(
          conn,
          credit_op("hold", 200, %{"operation_id" => "apply", "occurred_on" => "2026-10-02"})
        )

      applied = report(conn, "2026-10-02")
      assert applied["credit"] == credit_entry(issued, %{}, issued)

      {conn, _} =
        one(
          conn,
          cancel_op("hold", %{
            "operation_id" => "restore",
            "occurred_on" => "2026-10-03",
            "refund_method" => "cash"
          })
        )

      restored = report(conn, "2026-10-03")
      assert restored["credit"] == credit_entry(issued, %{}, issued)
      assert ledger(conn, "2026-10-03")["data"]["credit_liability_cents"] == issued
    end

    test "consumes, revokes, and absorbs credit without an apply column", %{conn: conn} do
      conn = issue_credit(conn, "guest-22", 1000)
      issued = Credits.issued_amount(1000)
      conn = open_group(conn, "park", "ams-canal")
      {conn, _} = one(conn, credit_op("park", 400, %{"operation_id" => "parked"}))
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, _} = one(conn, charge_op("pay-cancel-credit-source", %{"operation_id" => "claw"}))
      revoked = issued - 400

      clawed = report(conn, "2026-10-09")
      assert clawed["credit"]["movements"]["revoked_cents"] == revoked
      assert clawed["credit"]["closing_liability_cents"] == 400
      assert ledger(conn)["data"]["credit_liability_cents"] == 400
      assert ledger(conn)["data"]["credit_shortfall_cents"] == 400

      {conn, _} =
        one(
          conn,
          cancel_op("park", %{
            "operation_id" => "absorb",
            "occurred_on" => "2026-10-10",
            "refund_method" => "cash"
          })
        )

      absorbed = report(conn, "2026-10-10")
      assert absorbed["credit"]["movements"]["absorbed_cents"] == 400
      assert absorbed["credit"]["movements"]["expired_cents"] == 0
      assert absorbed["credit"]["closing_liability_cents"] == 0

      conn = issue_credit(conn, "guest-9", 100, "fee")
      fee_issued = Credits.issued_amount(100)

      conn =
        open_group(conn, "spent", "bbb-dock", %{
          "guest_id" => "guest-9",
          "rate_plan" => "advance_purchase"
        })

      {conn, _} =
        one(
          conn,
          credit_op("spent", fee_issued, %{"operation_id" => "use-fee", "guest_id" => "guest-9"})
        )

      {conn, _} =
        one(
          conn,
          cancel_op("spent", %{"operation_id" => "consume", "occurred_on" => "2026-12-01"})
        )

      consumed = report(conn, "2026-12-01")
      assert consumed["credit"]["movements"]["consumed_cents"] == fee_issued
      assert consumed["credit"]["closing_liability_cents"] == 0
      assert ledger(conn, "2026-12-01")["data"]["credit_liability_cents"] == 0
    end

    test "unused credit expires the day after expires_on without an operation", %{conn: conn} do
      conn = issue_credit(conn, "guest-22", 250, "aged")
      issued = Credits.issued_amount(250)
      lot = Repo.get_by!(Lot, source_operation_id: "aged")
      expires_on = Date.to_iso8601(lot.expires_on)
      following = lot.expires_on |> Date.add(1) |> Date.to_iso8601()
      {conn, _} = one(conn, start_op("2026-10-01"))

      through = report(conn, expires_on)
      assert through["credit"]["movements"]["expired_cents"] == 0
      assert through["credit"]["closing_liability_cents"] == issued
      assert through["status"] == "open"

      expired = report(conn, following)
      assert expired["credit"]["opening_liability_cents"] == issued
      assert expired["credit"]["movements"]["expired_cents"] == issued
      assert expired["credit"]["closing_liability_cents"] == 0
      assert ledger(conn, following)["data"]["credit_liability_cents"] == 0

      conn = open_group(conn, "partial", "ams-canal")

      {conn, _} =
        one(
          conn,
          credit_op("partial", 40, %{
            "operation_id" => "use-some",
            "occurred_on" => "2026-10-02"
          })
        )

      partial = report(conn, following)
      assert partial["credit"]["movements"]["expired_cents"] == issued - 40
      assert partial["credit"]["closing_liability_cents"] == 40
    end

    test "a backdated issue that is already expired posts issued and expired together", %{
      conn: conn
    } do
      {conn, _} = one(conn, start_op("2028-01-01"))

      conn =
        open_group(conn, "old", "ams-canal", %{
          "occurred_on" => "2026-01-01",
          "arrival_on" => "2026-03-01",
          "departure_on" => "2026-03-02"
        })

      {conn, _} =
        one(
          conn,
          payment_op("old", 100, %{"operation_id" => "old-pay", "occurred_on" => "2026-01-02"})
        )

      {conn, result} =
        one(
          conn,
          cancel_op("old", %{
            "operation_id" => "old-credit",
            "occurred_on" => "2026-01-03",
            "refund_method" => "hotel_credit"
          })
        )

      issued = result["credit_issued_cents"]
      day = report(conn, "2028-01-01")
      assert day["credit"]["movements"]["issued_cents"] == issued
      assert day["credit"]["movements"]["expired_cents"] == issued
      assert day["credit"]["closing_liability_cents"] == 0
      assert ledger(conn, "2028-01-01")["data"]["credit_liability_cents"] == 0
    end

    test "a chargeback after expiry does not revoke credit that the report already expires", %{
      conn: conn
    } do
      conn = issue_credit(conn, "guest-22", 120, "linger")
      issued = Credits.issued_amount(120)
      lot = Repo.get_by!(Lot, source_operation_id: "linger")
      following = lot.expires_on |> Date.add(1) |> Date.to_iso8601()
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, _} =
        one(
          conn,
          charge_op("pay-linger", %{
            "operation_id" => "late-claw",
            "occurred_on" => following
          })
        )

      day = report(conn, following)
      assert day["credit"]["movements"]["expired_cents"] == issued
      assert day["credit"]["movements"]["revoked_cents"] == 0
      assert day["credit"]["closing_liability_cents"] == 0
      assert ledger(conn, following)["data"]["credit_liability_cents"] == 0
    end

    test "immediate restoration expiry posts on the operation date", %{conn: conn} do
      conn = issue_credit(conn, "guest-22", 80, "soon")
      issued = Credits.issued_amount(80)
      lot = Repo.get_by!(Lot, source_operation_id: "soon")

      conn =
        open_group(conn, "hold", "ams-canal", %{
          "arrival_on" => "2028-01-20",
          "departure_on" => "2028-01-21"
        })

      {conn, _} = one(conn, credit_op("hold", issued, %{"operation_id" => "all"}))
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, _} =
        one(
          conn,
          cancel_op("hold", %{
            "operation_id" => "late-restore",
            "occurred_on" => Date.to_iso8601(lot.expires_on),
            "refund_method" => "cash"
          })
        )

      day = report(conn, Date.to_iso8601(lot.expires_on))
      assert day["credit"]["movements"]["expired_cents"] == issued
      assert day["credit"]["closing_liability_cents"] == 0
      assert ledger(conn, Date.to_iso8601(lot.expires_on))["data"]["credit_liability_cents"] == 0
    end
  end

  describe "reconciliation" do
    test "closing balances match the ledger after every posted movement", %{conn: conn} do
      conn = open_group(conn, "a", "ams-canal")
      conn = open_group(conn, "b", "ams-jordaan")
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, _} =
        one(conn, payment_op("a", 500, %{"operation_id" => "pa", "occurred_on" => "2026-10-02"}))

      {conn, _} =
        one(conn, payment_op("b", 200, %{"operation_id" => "pb", "occurred_on" => "2026-10-02"}))

      {conn, _} =
        one(
          conn,
          transfer_op("a", "b", 150, %{
            "operation_id" => "mv",
            "occurred_on" => "2026-10-03"
          })
        )

      {conn, _} =
        one(conn, cancel_op("b", %{"operation_id" => "rb", "occurred_on" => "2026-10-04"}))

      report = report(conn, "2026-10-04")
      assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) == 350
      assert ledger(conn)["data"]["cash_held_cents"] == 350
      assert ledger(conn)["data"]["cash_refunded_cents"] == 350
      assert_cash_identity(report)
      assert_credit_identity(report)
    end
  end

  describe "close_finance_period" do
    test "publishes through the cutoff and returns only the close fields", %{conn: conn} do
      conn = open_group(conn, "g", "ams-canal")
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, result} =
        one(
          conn,
          close_op("2026-10-03", %{
            "group_id" => "missing",
            "expected_revision" => 9,
            "destination_expected_revision" => 4
          })
        )

      assert result == %{
               "operation_id" => "close-2026-10-03",
               "status" => "applied",
               "period_end_on" => "2026-10-03"
             }

      assert Map.keys(result) |> Enum.sort() == ["operation_id", "period_end_on", "status"]
      refute Map.has_key?(result, "revision")
      refute Map.has_key?(result, "group_id")

      assert json_response(get(conn, "/api/v1/operations/close-2026-10-03"), 200)["data"] ==
               result

      assert report(conn, "2026-10-01")["status"] == "closed"
      assert report(conn, "2026-10-02")["status"] == "closed"
      assert report(conn, "2026-10-03")["status"] == "closed"
      assert report(conn, "2026-10-04")["status"] == "open"
      assert report_error(conn, "2026-09-30", 404)["error"]["code"] == "report_not_available"
    end

    test "rejects an unusable cutoff and remembers that rejection", %{conn: conn} do
      {conn, missing} =
        one(
          conn,
          close_op("2026-10-01", %{"operation_id" => "c1"}) |> Map.delete("period_end_on")
        )

      {conn, blank} =
        one(conn, close_op("2026-10-01", %{"operation_id" => "c2", "period_end_on" => ""}))

      {conn, bad} =
        one(
          conn,
          close_op("2026-10-01", %{"operation_id" => "c3", "period_end_on" => "2026-13-40"})
        )

      {conn, integer} =
        one(
          conn,
          close_op("2026-10-01", %{"operation_id" => "c4", "period_end_on" => 20_261_001})
        )

      {conn, early} =
        one(conn, close_op("2026-10-08", %{"operation_id" => "before-start"}))

      assert missing["code"] == "invalid_period"
      assert blank["code"] == "invalid_period"
      assert bad["code"] == "invalid_period"
      assert integer["code"] == "invalid_period"
      assert early["code"] == "invalid_period"
      assert report_error(conn, "2026-10-01", 404)["error"]["code"] == "report_not_available"

      {conn, _} = one(conn, start_op("2026-10-05"))

      {conn, replay} = one(conn, close_op("2026-10-08", %{"operation_id" => "before-start"}))
      assert replay == early
      assert report(conn, "2026-10-05")["status"] == "open"

      {conn, too_soon} =
        one(conn, close_op("2026-10-04", %{"operation_id" => "before-inception"}))

      assert too_soon["code"] == "invalid_period"

      {conn, closed} = one(conn, close_op("2026-10-05", %{"operation_id" => "first-close"}))
      assert closed["status"] == "applied"

      {conn, same} = one(conn, close_op("2026-10-05", %{"operation_id" => "same-cutoff"}))
      {conn, earlier} = one(conn, close_op("2026-10-01", %{"operation_id" => "earlier-cutoff"}))
      assert same["code"] == "invalid_period"
      assert earlier["code"] == "invalid_period"
      assert report(conn, "2026-10-06")["status"] == "open"

      {conn, again} = one(conn, close_op("2026-10-05", %{"operation_id" => "first-close"}))
      assert again == closed

      {conn, conflict} =
        one(conn, close_op("2026-10-09", %{"operation_id" => "first-close"}))

      assert conflict["code"] == "operation_id_conflict"
      assert report(conn, "2026-10-05")["status"] == "closed"
      assert report(conn, "2026-10-06")["status"] == "open"
    end

    test "a close does not change group, ledger, or payment current state", %{conn: conn} do
      conn = fund(conn, "g", "ams-canal", 250, "pay-state")
      {conn, _} = one(conn, start_op("2026-10-01"))
      before = snapshot(conn, "g")
      statement = payment(conn, "pay-state")

      {conn, _} = one(conn, close_op("2026-10-04"))

      assert snapshot(conn, "g") == before
      assert payment(conn, "pay-state") == statement
      assert report(conn, "2026-10-04")["cash"] == [cash_entry("ams-canal", 250, %{}, 250)]
    end

    test "same-batch activity before a close posts into it and activity after posts forward", %{
      conn: conn
    } do
      conn = open_group(conn, "g", "ams-canal")
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, results} =
        batch(conn, [
          payment_op("g", 100, %{"operation_id" => "inside", "occurred_on" => "2026-10-02"}),
          close_op("2026-10-03", %{"operation_id" => "close-batch"}),
          payment_op("g", 40, %{"operation_id" => "after", "occurred_on" => "2026-10-02"})
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied"]

      closed = report(conn, "2026-10-02")
      assert closed["status"] == "closed"
      assert closed["cash"] == [cash_entry("ams-canal", 0, %{"received_cents" => 100}, 100)]
      assert closed["late_adjustments"] == empty_late_adjustments()
      assert report(conn, "2026-10-03")["cash"] == [cash_entry("ams-canal", 100, %{}, 100)]

      opened = report(conn, "2026-10-04")
      assert opened["status"] == "open"
      assert opened["cash"] == [cash_entry("ams-canal", 100, %{}, 140)]
      assert hd(opened["cash"])["movements"]["received_cents"] == 0

      assert opened["late_adjustments"]["cash"] == [
               late_cash("ams-canal", %{"received_cents" => 40})
             ]

      assert opened["late_adjustments"]["credit"] == zero_credit_movements()
      assert_cash_identity(opened)
    end

    test "keeps a committed posting date when a later close is signed", %{conn: conn} do
      conn = open_group(conn, "g", "ams-canal")
      {conn, _} = one(conn, start_op("2026-10-01"))
      {conn, _} = one(conn, close_op("2026-10-05"))

      {conn, _} =
        one(
          conn,
          payment_op("g", 80, %{"operation_id" => "open-day", "occurred_on" => "2026-10-08"})
        )

      assert report(conn, "2026-10-08")["cash"] == [
               cash_entry("ams-canal", 0, %{"received_cents" => 80}, 80)
             ]

      assert report(conn, "2026-10-08")["late_adjustments"]["cash"] == []

      {conn, _} = one(conn, close_op("2026-10-10", %{"operation_id" => "close-later"}))
      frozen = report_body(conn, "2026-10-08")
      assert report(conn, "2026-10-08")["status"] == "closed"

      {conn, _} =
        one(
          conn,
          payment_op("g", 20, %{"operation_id" => "still-late", "occurred_on" => "2026-10-08"})
        )

      assert report_body(conn, "2026-10-08") == frozen
      next = report(conn, "2026-10-11")
      assert next["status"] == "open"
      assert next["cash"] == [cash_entry("ams-canal", 80, %{}, 100)]

      assert next["late_adjustments"]["cash"] == [
               late_cash("ams-canal", %{"received_cents" => 20})
             ]

      assert hd(next["cash"])["movements"]["received_cents"] == 0
    end

    test "published reports stay byte-for-byte stable across later activity and closes", %{
      conn: conn
    } do
      conn = open_group(conn, "g", "ams-canal")
      conn = open_group(conn, "other", "ams-jordaan")
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, _} =
        one(
          conn,
          payment_op("g", 100, %{"operation_id" => "seed", "occurred_on" => "2026-10-02"})
        )

      {conn, _} = one(conn, close_op("2026-10-04"))
      first = report_body(conn, "2026-10-02")
      middle = report_body(conn, "2026-10-03")
      assert middle =~ "\"status\":\"closed\""
      assert stored_payload(conn, "2026-10-02") == payload_of(first)

      {conn, _} =
        one(
          conn,
          payment_op("g", 25, %{"operation_id" => "late-pay", "occurred_on" => "2026-10-02"})
        )

      {conn, _} =
        one(
          conn,
          transfer_op("g", "other", 40, %{
            "operation_id" => "late-move",
            "occurred_on" => "2026-10-03"
          })
        )

      {conn, _} = one(conn, close_op("2026-10-06", %{"operation_id" => "close-next"}))

      assert report_body(conn, "2026-10-02") == first
      assert report_body(conn, "2026-10-03") == middle
      assert stored_payload(conn, "2026-10-02") == payload_of(first)
      assert report(conn, "2026-10-04")["status"] == "closed"
      assert report(conn, "2026-10-07")["status"] == "open"

      late = report(conn, "2026-10-05")
      assert late["status"] == "closed"

      assert late["late_adjustments"]["cash"] == [
               late_cash("ams-canal", %{
                 "received_cents" => 25,
                 "transferred_out_cents" => 40
               }),
               late_cash("ams-jordaan", %{"transferred_in_cents" => 40})
             ]

      canal = Enum.find(late["cash"], &(&1["property_id"] == "ams-canal"))
      assert canal["movements"]["received_cents"] == 0
      assert canal["movements"]["transferred_out_cents"] == 0
      assert canal["opening_held_cents"] == 100
      assert canal["closing_held_cents"] == 85
      assert_cash_identity(late)

      assert transferred_total(late, "transferred_in_cents") ==
               transferred_total(late, "transferred_out_cents")
    end

    test "a zero-net chargeback remains a signed late adjustment and does not rewrite the closed day",
         %{conn: conn} do
      conn = open_group(conn, "g", "ams-canal")
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, _} =
        one(conn, payment_op("g", 100, %{"operation_id" => "pay", "occurred_on" => "2026-10-02"}))

      {conn, _} =
        one(conn, cancel_op("g", %{"operation_id" => "refund", "occurred_on" => "2026-10-03"}))

      {conn, _} = one(conn, close_op("2026-10-03"))
      frozen = report_body(conn, "2026-10-03")

      assert report(conn, "2026-10-03")["cash"] == [
               cash_entry("ams-canal", 100, %{"refunded_cents" => 100}, 0)
             ]

      {conn, _} =
        one(conn, charge_op("pay", %{"operation_id" => "claw", "occurred_on" => "2026-10-02"}))

      assert report_body(conn, "2026-10-03") == frozen
      assert report(conn, "2026-10-04")["cash"] == []

      assert report(conn, "2026-10-04")["late_adjustments"]["cash"] == [
               late_cash("ams-canal", %{"refunded_cents" => -100, "charged_back_cents" => 100})
             ]

      assert payment(conn, "pay")["charged_back_cents"] == 100
      assert payment(conn, "pay")["refunded_cents"] == 0
      assert ledger(conn)["data"]["cash_charged_back_cents"] == 100
      assert ledger(conn)["data"]["cash_refunded_cents"] == 0
      assert ledger(conn)["data"]["cash_held_cents"] == 0
    end

    test "posts a backdated credit issue and revocation on the first open day", %{conn: conn} do
      conn = issue_credit(conn, "guest-22", 200, "aged-credit")
      issued = Credits.issued_amount(200)
      conn = open_group(conn, "again", "bbb-dock")
      {conn, _} = one(conn, start_op("2026-10-01"))
      {conn, _} = one(conn, close_op("2026-10-02"))

      {conn, _} =
        one(
          conn,
          charge_op("pay-aged-credit", %{
            "operation_id" => "late-revoke",
            "occurred_on" => "2026-09-15"
          })
        )

      revoked = report(conn, "2026-10-03")
      assert revoked["credit"]["movements"]["revoked_cents"] == 0
      assert revoked["credit"]["opening_liability_cents"] == issued
      assert revoked["credit"]["closing_liability_cents"] == 0
      assert revoked["late_adjustments"]["credit"]["revoked_cents"] == issued
      assert ledger(conn, "2026-10-03")["data"]["credit_liability_cents"] == 0

      {conn, _} =
        one(
          conn,
          payment_op("again", 100, %{
            "operation_id" => "fresh",
            "occurred_on" => "2026-10-03"
          })
        )

      {conn, issued_result} =
        one(
          conn,
          cancel_op("again", %{
            "operation_id" => "late-issue",
            "occurred_on" => "2026-10-01",
            "refund_method" => "hotel_credit"
          })
        )

      bonus = issued_result["credit_issued_cents"]
      day = report(conn, "2026-10-03")
      assert day["credit"]["movements"]["issued_cents"] == 0
      assert day["late_adjustments"]["credit"]["issued_cents"] == bonus
      assert day["late_adjustments"]["credit"]["revoked_cents"] == issued

      assert Enum.find(day["late_adjustments"]["cash"], &(&1["property_id"] == "bbb-dock"))[
               "movements"
             ]["converted_to_credit_cents"] == 100

      assert day["credit"]["closing_liability_cents"] == bonus
      assert ledger(conn, "2026-10-03")["data"]["credit_liability_cents"] == bonus
      assert_credit_identity(day)
    end

    test "a closed expiry day does not change when credit is later clawed back", %{conn: conn} do
      conn = issue_credit(conn, "guest-22", 120, "linger-close")
      issued = Credits.issued_amount(120)
      lot = Repo.get_by!(Lot, source_operation_id: "linger-close")
      starts = lot.expires_on |> Date.add(-1) |> Date.to_iso8601()
      following = lot.expires_on |> Date.add(1) |> Date.to_iso8601()
      after_close = lot.expires_on |> Date.add(2) |> Date.to_iso8601()

      {conn, _} = one(conn, start_op(starts, %{"operation_id" => "start-expiry"}))
      {conn, _} = one(conn, close_op(following, %{"operation_id" => "close-expiry"}))
      frozen = report_body(conn, following)
      assert report(conn, following)["credit"]["movements"]["expired_cents"] == issued
      assert report(conn, following)["status"] == "closed"

      {conn, _} =
        one(
          conn,
          charge_op("pay-linger-close", %{
            "operation_id" => "after-expiry",
            "occurred_on" => following
          })
        )

      assert report_body(conn, following) == frozen
      opened = report(conn, after_close)
      assert opened["status"] == "open"
      assert opened["credit"]["movements"]["revoked_cents"] == 0
      assert opened["late_adjustments"]["credit"]["revoked_cents"] == 0
      assert opened["credit"]["closing_liability_cents"] == 0
    end

    test "an old date before inception posts on the first open day, not on starts_on", %{
      conn: conn
    } do
      conn = open_group(conn, "g", "ams-canal")
      {conn, _} = one(conn, start_op("2026-10-10"))
      {conn, _} = one(conn, close_op("2026-10-12"))

      {conn, _} =
        one(
          conn,
          payment_op("g", 30, %{"operation_id" => "ancient", "occurred_on" => "2026-09-01"})
        )

      assert report(conn, "2026-10-10")["cash"] == []
      assert report(conn, "2026-10-12")["status"] == "closed"
      day = report(conn, "2026-10-13")

      assert day["late_adjustments"]["cash"] == [
               late_cash("ams-canal", %{"received_cents" => 30})
             ]

      assert day["cash"] == [cash_entry("ams-canal", 0, %{}, 30)]
    end

    test "a backdated reduction posts only as a late adjustment", %{conn: conn} do
      conn = open_group(conn, "g", "ams-canal")
      {conn, _} = one(conn, start_op("2026-10-01"))

      {conn, _} =
        one(conn, payment_op("g", 200, %{"operation_id" => "pay", "occurred_on" => "2026-10-02"}))

      {conn, _} = one(conn, close_op("2026-10-02"))
      frozen = report_body(conn, "2026-10-02")

      {conn, _} =
        one(
          conn,
          reduce_op("pay", 50, %{"operation_id" => "late-trim", "occurred_on" => "2026-10-02"})
        )

      assert report_body(conn, "2026-10-02") == frozen
      day = report(conn, "2026-10-03")
      assert day["cash"] == [cash_entry("ams-canal", 200, %{}, 150)]
      assert hd(day["cash"])["movements"]["reduced_cents"] == 0
      assert day["late_adjustments"]["cash"] == [late_cash("ams-canal", %{"reduced_cents" => 50})]
      assert ledger(conn)["data"]["cash_reduced_cents"] == 50
      assert ledger(conn)["data"]["cash_held_cents"] == 150
      assert_cash_identity(day)
    end

    test "calendar expiry after a close stays ordinary and uses the published closing", %{
      conn: conn
    } do
      conn = issue_credit(conn, "guest-22", 90, "open-expiry")
      issued = Credits.issued_amount(90)
      lot = Repo.get_by!(Lot, source_operation_id: "open-expiry")
      following = lot.expires_on |> Date.add(1) |> Date.to_iso8601()
      {conn, _} = one(conn, start_op("2026-10-01", %{"operation_id" => "start-open-exp"}))
      {conn, _} = one(conn, close_op("2026-10-03", %{"operation_id" => "close-before-exp"}))

      day = report(conn, following)
      assert day["status"] == "open"
      assert day["credit"]["opening_liability_cents"] == issued
      assert day["credit"]["movements"]["expired_cents"] == issued
      assert day["late_adjustments"]["credit"]["expired_cents"] == 0
      assert day["credit"]["closing_liability_cents"] == 0
      assert_credit_identity(day)
    end

    test "a rejected close does not stop the batch or publish a report", %{conn: conn} do
      conn = open_group(conn, "g", "ams-canal")

      {conn, results} =
        batch(conn, [
          close_op("2026-10-02", %{"operation_id" => "too-early"}),
          start_op("2026-10-01", %{"operation_id" => "then-start"}),
          payment_op("g", 15, %{"operation_id" => "kept", "occurred_on" => "2026-10-02"})
        ])

      assert Enum.map(results, & &1["status"]) == ["rejected", "applied", "applied"]
      assert hd(results)["code"] == "invalid_period"
      assert report(conn, "2026-10-02")["status"] == "open"

      assert report(conn, "2026-10-02")["cash"] == [
               cash_entry("ams-canal", 0, %{"received_cents" => 15}, 15)
             ]
    end
  end

  defp empty_report(date) do
    %{
      "date" => date,
      "status" => "open",
      "cash" => [],
      "credit" => credit_entry(0, %{}, 0),
      "late_adjustments" => empty_late_adjustments()
    }
  end

  defp empty_late_adjustments do
    %{"cash" => [], "credit" => zero_credit_movements()}
  end

  defp cash_entry(property_id, opening, movements, closing) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => Map.merge(zero_cash_movements(), movements),
      "closing_held_cents" => closing
    }
  end

  defp credit_entry(opening, movements, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" => Map.merge(zero_credit_movements(), movements),
      "closing_liability_cents" => closing
    }
  end

  defp zero_cash_movements do
    %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
  end

  defp zero_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  defp transferred_in(report) do
    Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_in_cents"]))
  end

  defp transferred_out(report) do
    Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_out_cents"]))
  end

  defp assert_cash_identity(report) do
    late_by_property =
      Map.new(report["late_adjustments"]["cash"], &{&1["property_id"], &1["movements"]})

    Enum.each(report["cash"], fn entry ->
      moves = entry["movements"]
      late = Map.get(late_by_property, entry["property_id"], zero_cash_movements())

      assert entry["closing_held_cents"] ==
               entry["opening_held_cents"] + moves["received_cents"] + late["received_cents"] +
                 moves["transferred_in_cents"] + late["transferred_in_cents"] -
                 moves["transferred_out_cents"] - late["transferred_out_cents"] -
                 moves["refunded_cents"] - late["refunded_cents"] - moves["retained_cents"] -
                 late["retained_cents"] - moves["converted_to_credit_cents"] -
                 late["converted_to_credit_cents"] - moves["reduced_cents"] -
                 late["reduced_cents"] - moves["charged_back_cents"] - late["charged_back_cents"]
    end)
  end

  defp assert_credit_identity(report) do
    credit = report["credit"]
    moves = credit["movements"]
    late = report["late_adjustments"]["credit"]

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + moves["issued_cents"] + late["issued_cents"] -
               moves["expired_cents"] - late["expired_cents"] - moves["consumed_cents"] -
               late["consumed_cents"] - moves["revoked_cents"] - late["revoked_cents"] -
               moves["absorbed_cents"] - late["absorbed_cents"]
  end

  defp fund(conn, group_id, property_id, amount, operation_id, occurred_on \\ "2026-10-02") do
    conn = open_group(conn, group_id, property_id, %{"occurred_on" => "2026-09-01"})

    {conn, result} =
      one(
        conn,
        payment_op(group_id, amount, %{
          "operation_id" => operation_id,
          "occurred_on" => occurred_on
        })
      )

    assert result["status"] == "applied"
    conn
  end

  defp open_group(conn, group_id, property_id, overrides \\ %{}) do
    {conn, result} =
      one(
        conn,
        open_op(
          group_id,
          Map.merge(%{"property_id" => property_id, "rooms" => [room("a", 5000)]}, overrides)
        )
      )

    assert result["status"] == "applied", inspect(result)
    conn
  end

  defp issue_credit(conn, guest_id, cash, operation_id \\ "cancel-credit-source") do
    source = "src-#{operation_id}"

    {conn, _} =
      one(
        conn,
        open_op(source, %{
          "operation_id" => "open-#{operation_id}",
          "guest_id" => guest_id,
          "occurred_on" => "2026-09-01",
          "arrival_on" => "2026-12-20",
          "departure_on" => "2026-12-21",
          "rooms" => [room("a", cash * 5)]
        })
      )

    {conn, _} =
      one(
        conn,
        payment_op(source, cash, %{
          "operation_id" => "pay-#{operation_id}",
          "occurred_on" => "2026-09-02"
        })
      )

    {conn, cancelled} =
      one(
        conn,
        cancel_op(source, %{
          "operation_id" => operation_id,
          "occurred_on" => "2026-09-03",
          "refund_method" => "hotel_credit"
        })
      )

    assert cancelled["status"] == "applied", inspect(cancelled)
    assert cancelled["credit_issued_cents"] == Credits.issued_amount(cash)
    conn
  end

  defp snapshot(conn, group_id) do
    data = json_response(get(conn, "/api/v1/groups/#{group_id}"), 200)["data"]

    %{
      revision: data["revision"],
      cash: data["cash_paid_cents"],
      credit: data["credit_paid_cents"],
      ledger: ledger(conn)["data"]
    }
  end

  defp report(conn, date) do
    json_response(report_conn(conn, date), 200)["data"]
  end

  defp report_error(conn, nil, status) do
    conn = recycle(conn) |> put_req_header("accept", "application/json")
    json_response(get(conn, "/api/v1/finance/daily-report"), status)
  end

  defp report_error(conn, date, status) do
    json_response(report_conn(conn, date), status)
  end

  defp report_conn(conn, date) do
    conn
    |> recycle()
    |> put_req_header("accept", "application/json")
    |> get("/api/v1/finance/daily-report?date=#{date}")
  end

  defp ledger(conn, on \\ nil) do
    path = if on, do: "/api/v1/ledger?on=#{on}", else: "/api/v1/ledger"
    json_response(get(conn, path), 200)
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp batch(conn, operations) do
    conn = post_batch(conn, operations)
    {conn, json_response(conn, 200)["results"]}
  end

  defp one(conn, operation) do
    {conn, [result]} = batch(conn, [operation])
    {conn, result}
  end

  defp room(room_id, rate), do: %{"room_id" => room_id, "nightly_rate_cents" => rate}

  defp open_op(group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-09-01",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-20",
        "departure_on" => "2026-12-21",
        "rate_plan" => "flexible",
        "rooms" => [room("a", 5000)]
      },
      overrides
    )
  end

  defp payment_op(group_id, amount, overrides) do
    Map.merge(
      %{
        "operation_id" => "pay-#{group_id}-#{amount}",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp credit_op(group_id, amount, overrides) do
    Map.merge(
      %{
        "operation_id" => "credit-#{group_id}-#{amount}",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-06",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp cancel_op(group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => group_id
      },
      overrides
    )
  end

  defp transfer_op(source_id, destination_id, amount, overrides) do
    Map.merge(
      %{
        "operation_id" => "transfer-#{source_id}-#{destination_id}-#{amount}",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-07",
        "source_group_id" => source_id,
        "destination_group_id" => destination_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp reduce_op(payment_operation_id, amount, overrides) do
    Map.merge(
      %{
        "operation_id" => "reduce-#{payment_operation_id}-#{amount}",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-08",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp charge_op(payment_operation_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "charge-#{payment_operation_id}",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-09",
        "payment_operation_id" => payment_operation_id
      },
      overrides
    )
  end

  defp start_op(starts_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "start-#{starts_on}",
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-10-01",
        "starts_on" => starts_on
      },
      overrides
    )
  end

  defp close_op(period_end_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "close-#{period_end_on}",
        "type" => "close_finance_period",
        "occurred_on" => "2026-10-20",
        "period_end_on" => period_end_on
      },
      overrides
    )
  end

  defp late_cash(property_id, movements) do
    %{"property_id" => property_id, "movements" => Map.merge(zero_cash_movements(), movements)}
  end

  defp report_body(conn, date) do
    response(report_conn(conn, date), 200)
  end

  defp payload_of(body) do
    body
    |> String.trim_leading("{\"data\":")
    |> String.replace_suffix("}", "")
  end

  defp stored_payload(_conn, date) do
    {:ok, day} = Date.from_iso8601(date)

    Repo.get_by!(GroupStay.Finance.PublishedReport, report_on: day).payload
  end

  defp payment(conn, operation_id) do
    json_response(get(conn, "/api/v1/payments/#{operation_id}"), 200)["data"]
  end

  defp transferred_total(report, key) do
    ordinary = Enum.sum(Enum.map(report["cash"], & &1["movements"][key]))
    late = Enum.sum(Enum.map(report["late_adjustments"]["cash"], & &1["movements"][key]))
    ordinary + late
  end
end
