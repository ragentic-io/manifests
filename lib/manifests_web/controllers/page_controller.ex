defmodule ManifestsWeb.PageController do
  use ManifestsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
