function period(now, nightHour, dayHour) {
  var hour = now.getHours()
  if (nightHour === dayHour) return "night"
  if (nightHour > dayHour) return (hour >= nightHour || hour < dayHour) ? "night" : "day"
  return (hour >= nightHour && hour < dayHour) ? "night" : "day"
}

function nextDelay(now, enabled, nightHour, dayHour) {
  // Equal hours mean permanent night mode, so there is no next transition.
  if (!enabled || nightHour === dayHour) return 0
  var next = Infinity
  var hours = [nightHour, dayHour]
  for (var i = 0; i < hours.length; i++) {
    var boundary = new Date(now.getTime())
    boundary.setHours(hours[i], 0, 0, 0)
    if (boundary.getTime() <= now.getTime()) {
      boundary = new Date(now.getTime())
      boundary.setDate(boundary.getDate() + 1)
      boundary.setHours(hours[i], 0, 0, 0)
    }
    next = Math.min(next, boundary.getTime() - now.getTime())
  }
  return next
}

if (typeof module !== "undefined") {
  module.exports = { period: period, nextDelay: nextDelay }
}
