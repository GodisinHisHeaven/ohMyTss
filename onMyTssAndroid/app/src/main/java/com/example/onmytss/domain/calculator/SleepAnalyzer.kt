package com.example.onmytss.domain.calculator

import com.example.onmytss.domain.model.SleepQuality
import java.util.Date

object SleepAnalyzer {

    fun calculateSleepQuality(samples: List<SleepSample>): SleepQuality? {
        if (samples.isEmpty()) return null
        val sleepSessions = groupIntoSessions(samples)
        val mainSession = sleepSessions.maxByOrNull { it.duration } ?: return null

        val durationScore = calculateDurationScore(mainSession.duration)
        val consistencyScore = calculateConsistencyScore(mainSession)
        val deepSleepScore = calculateDeepSleepScore(mainSession)
        val totalScore = (durationScore + consistencyScore + deepSleepScore).toInt().coerceIn(0, 100)

        return SleepQuality(
            totalDuration = mainSession.duration,
            deepSleepDuration = mainSession.deepDuration,
            remDuration = mainSession.remDuration,
            awakeTime = mainSession.awakeDuration,
            qualityScore = totalScore,
            startTime = mainSession.startDate,
            endTime = mainSession.endDate
        )
    }

    private fun groupIntoSessions(samples: List<SleepSample>): List<SleepSession> {
        val sessions = mutableListOf<SleepSession>()
        var currentSession: SleepSession? = null
        val sortedSamples = samples.sortedBy { it.startDate.time }

        for (sample in sortedSamples) {
            val session = currentSession
            if (session != null && (sample.startDate.time - session.endDate.time) < 2 * 3600 * 1000) {
                currentSession = extendSession(session, sample)
            } else {
                session?.let { sessions.add(it) }
                currentSession = SleepSession.fromSample(sample)
            }
        }
        currentSession?.let { sessions.add(it) }
        return sessions
    }

    private fun extendSession(session: SleepSession, sample: SleepSample): SleepSession {
        val newEnd = Date(maxOf(session.endDate.time, sample.endDate.time))
        val duration = (newEnd.time - session.startDate.time) / 1000.0
        val sampleDuration = (sample.endDate.time - sample.startDate.time) / 1000.0

        var deep = session.deepDuration
        var rem = session.remDuration
        var awake = session.awakeDuration

        when (sample.stage) {
            SleepStage.DEEP -> deep += sampleDuration
            SleepStage.REM -> rem += sampleDuration
            SleepStage.AWAKE -> awake += sampleDuration
            else -> {}
        }

        return session.copy(endDate = newEnd, duration = duration, deepDuration = deep, remDuration = rem, awakeDuration = awake)
    }

    private fun calculateDurationScore(duration: Double): Double {
        val hours = duration / 3600.0
        return when {
            hours in 7.0..9.0 -> 40.0
            hours in 6.0..7.0 -> 30.0 + (hours - 6.0) * 10.0
            hours in 9.0..10.0 -> 40.0 - (hours - 9.0) * 10.0
            hours in 5.0..6.0 -> (hours - 5.0) * 30.0
            hours in 10.0..11.0 -> 30.0 - (hours - 10.0) * 30.0
            else -> 0.0
        }
    }

    private fun calculateConsistencyScore(session: SleepSession): Double {
        if (session.duration <= 0) return 0.0
        val awakeRatio = session.awakeDuration / session.duration
        return when {
            awakeRatio < 0.05 -> 30.0
            awakeRatio < 0.10 -> 30.0 - (awakeRatio - 0.05) / 0.05 * 10.0
            awakeRatio < 0.20 -> 20.0 - (awakeRatio - 0.10) / 0.10 * 10.0
            else -> maxOf(0.0, 10.0 - (awakeRatio - 0.20) / 0.10 * 10.0)
        }
    }

    private fun calculateDeepSleepScore(session: SleepSession): Double {
        if (session.duration <= 0) return 0.0
        val deepRatio = session.deepDuration / session.duration
        return when {
            deepRatio in 0.15..0.25 -> 30.0
            deepRatio in 0.10..0.15 -> (deepRatio - 0.10) / 0.05 * 30.0
            deepRatio in 0.25..0.30 -> 30.0 - (deepRatio - 0.25) / 0.05 * 15.0
            else -> 0.0
        }
    }
}

enum class SleepStage {
    AWAKE, LIGHT, DEEP, REM, UNKNOWN
}

data class SleepSample(
    val startDate: Date,
    val endDate: Date,
    val stage: SleepStage
)

private data class SleepSession(
    val startDate: Date,
    val endDate: Date,
    val duration: Double = 0.0,
    val deepDuration: Double = 0.0,
    val remDuration: Double = 0.0,
    val awakeDuration: Double = 0.0
) {
    companion object {
        fun fromSample(sample: SleepSample): SleepSession {
            val duration = (sample.endDate.time - sample.startDate.time) / 1000.0
            return SleepSession(
                startDate = sample.startDate,
                endDate = sample.endDate,
                duration = duration,
                deepDuration = if (sample.stage == SleepStage.DEEP) duration else 0.0,
                remDuration = if (sample.stage == SleepStage.REM) duration else 0.0,
                awakeDuration = if (sample.stage == SleepStage.AWAKE) duration else 0.0
            )
        }
    }
}
