package studio.voxsum

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * The three interface languages stay in step: same keys, same placeholders, and each Chinese
 * file uses only its own script (a Simplified character in zh-TW, or a Traditional one in zh-CN,
 * is a bug the user would see). Reads the resource XML and the bundled OpenCC dictionaries.
 */
class ResourceLanguageTest {
    private fun res(dir: String) = File("src/main/res/$dir/strings.xml")

    /** name -> all text of the element (every plural item joined). */
    private fun load(dir: String): Map<String, String> {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(res(dir))
        val out = LinkedHashMap<String, String>()
        val nodes = doc.documentElement.childNodes
        for (i in 0 until nodes.length) {
            val n = nodes.item(i)
            val name = n.attributes?.getNamedItem("name")?.nodeValue ?: continue
            if (n.attributes?.getNamedItem("translatable")?.nodeValue == "false") continue
            out[name] = n.textContent.trim()
        }
        return out
    }

    private fun placeholders(s: String) = Regex("%\\d*\\$?[sdf]").findAll(s).map { it.value }.toSortedSet().toList()

    private val en = load("values")
    private val tw = load("values-zh-rTW")
    private val cn = load("values-zh-rCN")

    @Test fun sameKeysInEveryLanguage() {
        assertEquals("zh-TW vs en", en.keys, tw.keys)
        assertEquals("zh-CN vs en", en.keys, cn.keys)
    }

    @Test fun samePlaceholdersInEveryLanguage() {
        for ((k, v) in en) {
            assertEquals("placeholders of $k (zh-TW)", placeholders(v), placeholders(tw.getValue(k)))
            assertEquals("placeholders of $k (zh-CN)", placeholders(v), placeholders(cn.getValue(k)))
        }
    }

    private fun dict(name: String): Map<String, String> =
        File("src/main/assets/opencc/$name").readLines().mapNotNull { l ->
            val p = l.split('\t'); if (p.size == 2 && p[1].isNotBlank()) p[0] to p[1].trim().split(' ')[0] else null
        }.toMap()

    @Test fun eachChineseFileKeepsToItsScript() {
        // A character belongs to only one script when a dictionary maps it away and no entry of the
        // same dictionary maps anything TO it (shared characters such as 出 or 面 appear in both).
        val ts = dict("TSCharacters.txt")                       // Traditional -> Simplified
        val st = dict("STCharacters.txt")                       // Simplified -> Traditional
        val traditionalOnly = ts.filter { (k, v) -> k != v && k !in ts.values.toSet() }.keys
        val simplifiedOnly = st.filter { (k, v) -> k != v && k !in st.values.toSet() }.keys
        val twBad = tw.values.flatMap { it.toList() }.filter { it.toString() in simplifiedOnly }.toSet()
        val cnBad = cn.values.flatMap { it.toList() }.filter { it.toString() in traditionalOnly }.toSet()
        assertTrue("Simplified characters in zh-TW: $twBad", twBad.isEmpty())
        assertTrue("Traditional characters in zh-CN: $cnBad", cnBad.isEmpty())
    }
}
