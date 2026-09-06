defmodule GroupStayWeb.ErrorJSONTest do
  use GroupStayWeb.ConnCase, async: true

  test "renders 404" do
    assert GroupStayWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders malformed JSON with the partner API error envelope" do
    assert GroupStayWeb.ErrorJSON.render("400.json", %{}) == %{error: %{code: "invalid_json"}}
  end

  test "renders 500" do
    assert GroupStayWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
