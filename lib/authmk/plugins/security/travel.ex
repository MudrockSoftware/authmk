defmodule Authmk.Plugins.Security.Travel do
  @moduledoc false
  # How fast someone would have traveled between two sign-ins.

  @earth_radius_km 6371.0

  @doc "Kilometers between two points (haversine)."
  def distance_km({lat1, lon1}, {lat2, lon2}) do
    {lat1, lon1, lat2, lon2} = {radians(lat1), radians(lon1), radians(lat2), radians(lon2)}

    a =
      :math.pow(:math.sin((lat2 - lat1) / 2), 2) +
        :math.cos(lat1) * :math.cos(lat2) * :math.pow(:math.sin((lon2 - lon1) / 2), 2)

    2 * @earth_radius_km * :math.asin(:math.sqrt(a))
  end

  @doc "Km/h between two points `seconds` apart (at least a minute, for clocks and nearby cities)."
  def speed_kmh(from, to, seconds), do: distance_km(from, to) / (max(seconds, 60) / 3600)

  defp radians(degrees), do: degrees * :math.pi() / 180
end
