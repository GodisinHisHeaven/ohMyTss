package com.example.onmytss.data.local.db

import androidx.room.TypeConverter
import com.example.onmytss.domain.model.enums.Sport
import java.util.Date

class Converters {

    @TypeConverter
    fun fromTimestamp(value: Long?): Date? {
        return value?.let { Date(it) }
    }

    @TypeConverter
    fun dateToTimestamp(date: Date?): Long? {
        return date?.time
    }

    @TypeConverter
    fun fromSportList(value: List<Sport>?): String? {
        return value?.joinToString(",") { it.name }
    }

    @TypeConverter
    fun toSportList(value: String?): List<Sport>? {
        return value?.split(",")?.map { Sport.valueOf(it) }
    }
}
