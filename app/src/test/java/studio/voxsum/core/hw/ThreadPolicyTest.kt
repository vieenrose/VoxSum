package studio.voxsum.core.hw

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ThreadPolicyTest {
    private val sd855 = listOf(2840000L, 2420000L, 2420000L, 2420000L, 1790000L, 1790000L, 1790000L, 1790000L)

    @Test fun upperCoresSkipTheEfficiencyCluster() {
        assertEquals(4, ThreadPolicy.upperCores(sd855, 8))
        assertEquals(8, ThreadPolicy.upperCores(List(8) { 2000000L }, 8))   // flat SoC: all cores
        assertEquals(6, ThreadPolicy.upperCores(emptyList(), 6))            // cpufreq unreadable
    }

    @Test fun heuristicIsClampedToTwoToFourAndToTheCoreCount() {
        assertEquals(4, ThreadPolicy.heuristic(sd855, 8))
        assertEquals(2, ThreadPolicy.heuristic(listOf(2000000L, 1000000L, 1000000L, 1000000L), 4))   // 1 upper core → floor 2
        assertEquals(2, ThreadPolicy.heuristic(emptyList(), 2))
        assertEquals(1, ThreadPolicy.heuristic(emptyList(), 1))   // a single-core phone cannot have 2
    }

    @Test fun candidatesStopAtTheCoreCount() {
        assertEquals(listOf(2, 3, 4), ThreadPolicy.candidates(8))                // SD855: 4 fast cores
        assertEquals(listOf(2, 3, 4, 5, 6), ThreadPolicy.candidates(8, 8))       // 8 fast cores: capped at 6
        assertEquals(listOf(2, 3, 4, 5), ThreadPolicy.candidates(8, 5))
        assertEquals(6, ThreadPolicy.resolve(ThreadMode.T6, null, 4, false, 8))
        assertEquals(4, ThreadPolicy.heuristic(List(8) { 2000000L }, 8))         // no benchmark: stay at 4
        assertEquals(listOf(2, 3), ThreadPolicy.candidates(3))
        assertEquals(listOf(1), ThreadPolicy.candidates(1))
    }

    @Test fun pickTakesTheFewestThreadsWithinFivePercentOfTheBest() {
        assertEquals(3, ThreadPolicy.pick(mapOf(2 to 100.0, 3 to 150.0, 4 to 152.0)))   // 4 adds 1 %
        assertEquals(4, ThreadPolicy.pick(mapOf(2 to 100.0, 3 to 140.0, 4 to 190.0)))
        assertEquals(2, ThreadPolicy.pick(mapOf(2 to 100.0, 3 to 90.0, 4 to 60.0)))     // contention: fewer is faster
        assertNull(ThreadPolicy.pick(emptyMap()))
    }

    @Test fun resolveHonoursTheModeThenTheBenchmarkThenTheHeuristic() {
        assertEquals(3, ThreadPolicy.resolve(ThreadMode.T3, 4, 4, false, 8))
        assertEquals(2, ThreadPolicy.resolve(ThreadMode.T4, null, 4, false, 2))          // never above the cores
        assertEquals(3, ThreadPolicy.resolve(ThreadMode.AUTO, 3, 4, false, 8))
        assertEquals(4, ThreadPolicy.resolve(ThreadMode.AUTO, null, 4, false, 8))
        assertEquals(2, ThreadPolicy.resolve(ThreadMode.AUTO, 4, 4, true, 8))            // capped after a failure
        assertEquals(4, ThreadPolicy.resolve(ThreadMode.T4, 2, 2, true, 8))              // a manual choice wins over the cap
    }
}

class ThreadBenchTest {
    @Test fun scoresEveryCandidateWithAPositiveThroughput() {
        val t0 = System.nanoTime()
        val scores = ThreadBench.run(listOf(2, 3))
        val ms = (System.nanoTime() - t0) / 1_000_000
        println("bench ${scores.mapValues { it.value.toInt() }} in $ms ms")
        assertEquals(setOf(2, 3), scores.keys)
        org.junit.Assert.assertTrue(scores.values.all { it > 0 })
    }
}
