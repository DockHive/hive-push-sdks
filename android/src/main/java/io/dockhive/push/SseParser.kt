package io.dockhive.push

/** Parses Server-Sent Events, one line at a time. */
internal class SseParser {
    data class Event(val id: String?, val event: String, val data: String)

    private var eventName = ""
    private val dataLines = ArrayList<String>()
    private var lastId: String? = null

    /** Feeds one line (without its line ending); returns an event when a blank line ends one. */
    fun line(line: String): Event? {
        if (line.isEmpty()) {
            val ev = if (dataLines.isEmpty()) null
            else Event(lastId, eventName.ifEmpty { "message" }, dataLines.joinToString("\n"))
            eventName = ""
            dataLines.clear()
            return ev
        }
        if (line.startsWith(":")) return null // comment (": ping")
        val colon = line.indexOf(':')
        val field = if (colon < 0) line else line.substring(0, colon)
        var value = if (colon < 0) "" else line.substring(colon + 1)
        if (value.startsWith(" ")) value = value.substring(1)
        when (field) {
            "event" -> eventName = value
            "data" -> dataLines.add(value)
            "id" -> lastId = value
        }
        return null
    }
}
