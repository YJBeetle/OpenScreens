//! Conservative Tight JPEG quality adaptation.
//!
//! The controller only reacts when a meaningful amount of data is flowing:
//! small periodic updates (a clock, a blinking cursor) must not be mistaken
//! for a congested link. Windows with fewer than three updates, or with very
//! little traffic, are ignored.

use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy)]
pub(crate) struct QualityConfig {
    pub window: Duration,
    pub warmup: Duration,
    pub dwell: Duration,
    pub slow_interval: Duration,
    pub fast_interval: Duration,
    pub slow_min_bytes_per_second: f64,
    pub fast_max_bytes_per_second: f64,
    pub min_quality: u8,
}

impl Default for QualityConfig {
    fn default() -> Self {
        Self {
            window: Duration::from_secs(2),
            warmup: Duration::from_secs(3),
            dwell: Duration::from_secs(4),
            slow_interval: Duration::from_millis(250),
            fast_interval: Duration::from_millis(45),
            slow_min_bytes_per_second: 400_000.0,
            fast_max_bytes_per_second: 25_000_000.0,
            min_quality: 2,
        }
    }
}

/// Quality levels are TightVNC's 0 (smallest) through 9 (best).
pub(crate) struct AdaptiveQuality {
    config: QualityConfig,
    ceiling: u8,
    current: u8,
    started_at: Instant,
    window_start: Instant,
    last_update: Option<Instant>,
    updates: u32,
    bytes: u64,
    interval_sum: Duration,
    intervals: u32,
    last_change: Option<Instant>,
    slow_windows: u8,
    good_windows: u8,
}

impl AdaptiveQuality {
    pub(crate) fn new(ceiling: u8, now: Instant) -> Self {
        Self::with_config(ceiling, now, QualityConfig::default())
    }

    pub(crate) fn with_config(ceiling: u8, now: Instant, config: QualityConfig) -> Self {
        let ceiling = ceiling.min(9);
        Self {
            config,
            ceiling,
            current: ceiling,
            started_at: now,
            window_start: now,
            last_update: None,
            updates: 0,
            bytes: 0,
            interval_sum: Duration::ZERO,
            intervals: 0,
            last_change: None,
            slow_windows: 0,
            good_windows: 0,
        }
    }

    #[cfg(test)]
    pub(crate) fn current(&self) -> u8 {
        self.current
    }

    /// Feeds one completed framebuffer update. Returns a new quality level
    /// when the caller should re-advertise encodings.
    pub(crate) fn observe(&mut self, now: Instant, bytes: u64) -> Option<u8> {
        if now.saturating_duration_since(self.started_at) < self.config.warmup {
            self.window_start = now;
            self.last_update = Some(now);
            self.updates = 0;
            self.bytes = 0;
            self.interval_sum = Duration::ZERO;
            self.intervals = 0;
            return None;
        }

        if let Some(last) = self.last_update {
            let gap = now.saturating_duration_since(last);
            if gap <= Duration::from_secs(3) {
                self.interval_sum += gap;
                self.intervals += 1;
            }
        }
        self.last_update = Some(now);
        self.updates += 1;
        self.bytes = self.bytes.saturating_add(bytes);

        let elapsed = now.saturating_duration_since(self.window_start);
        if elapsed < self.config.window {
            return None;
        }

        let change = self.evaluate(now, elapsed);
        self.window_start = now;
        self.updates = 0;
        self.bytes = 0;
        self.interval_sum = Duration::ZERO;
        self.intervals = 0;
        change
    }

    fn evaluate(&mut self, now: Instant, elapsed: Duration) -> Option<u8> {
        if self.updates < 2 {
            return None;
        }
        let dwell_ok = self
            .last_change
            .is_none_or(|last| now.saturating_duration_since(last) >= self.config.dwell);
        if !dwell_ok {
            return None;
        }

        let average_interval = if self.intervals == 0 {
            Duration::MAX
        } else {
            self.interval_sum / self.intervals
        };
        let bytes_per_second = self.bytes as f64 / elapsed.as_secs_f64();

        if average_interval > self.config.slow_interval
            && bytes_per_second > self.config.slow_min_bytes_per_second
            && self.current > self.config.min_quality
        {
            self.good_windows = 0;
            self.slow_windows += 1;
            if self.slow_windows >= 2 {
                self.slow_windows = 0;
                self.current -= 1;
                self.last_change = Some(now);
                return Some(self.current);
            }
            return None;
        }

        if average_interval < self.config.fast_interval
            && bytes_per_second < self.config.fast_max_bytes_per_second
            && self.current < self.ceiling
        {
            self.slow_windows = 0;
            self.good_windows += 1;
            if self.good_windows >= 2 {
                self.good_windows = 0;
                self.current += 1;
                self.last_change = Some(now);
                return Some(self.current);
            }
            return None;
        }

        self.slow_windows = 0;
        self.good_windows = 0;
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> QualityConfig {
        QualityConfig {
            window: Duration::from_millis(500),
            warmup: Duration::ZERO,
            dwell: Duration::from_millis(100),
            slow_interval: Duration::from_millis(150),
            ..QualityConfig::default()
        }
    }

    #[test]
    fn lowers_quality_after_two_slow_windows() {
        let start = Instant::now();
        let mut quality = AdaptiveQuality::with_config(9, start, config());
        let mut now = start;
        let mut changes = Vec::new();
        // 200 KB every 200 ms is ~1 MB/s across slower-than-150 ms updates.
        for _ in 0..6 {
            now += Duration::from_millis(200);
            if let Some(level) = quality.observe(now, 200_000) {
                changes.push(level);
            }
        }
        assert_eq!(changes, vec![8]);
        assert_eq!(quality.current(), 8);
    }

    #[test]
    fn ignores_sparse_updates() {
        let start = Instant::now();
        let mut quality = AdaptiveQuality::with_config(9, start, config());
        let mut now = start;
        for _ in 0..3 {
            now += Duration::from_secs(5);
            assert_eq!(quality.observe(now, 10_000), None);
        }
        assert_eq!(quality.current(), 9);
    }

    #[test]
    fn ignores_low_traffic_windows() {
        let start = Instant::now();
        let mut quality = AdaptiveQuality::with_config(9, start, config());
        let mut now = start;
        // Slow updates with hardly any traffic (a clock) are not congestion.
        for _ in 0..12 {
            now += Duration::from_millis(400);
            assert_eq!(quality.observe(now, 4_000), None);
        }
        assert_eq!(quality.current(), 9);
    }

    #[test]
    fn lowers_then_recovers() {
        let start = Instant::now();
        let mut quality = AdaptiveQuality::with_config(9, start, config());
        let mut now = start;
        for _ in 0..6 {
            now += Duration::from_millis(200);
            if let Some(level) = quality.observe(now, 200_000) {
                assert_eq!(level, 8);
            }
        }
        assert_eq!(quality.current(), 8);

        let mut raised = None;
        for _ in 0..80 {
            now += Duration::from_millis(20);
            if let Some(level) = quality.observe(now, 5_000) {
                raised = Some(level);
                break;
            }
        }
        assert_eq!(raised, Some(9));
    }

    #[test]
    fn waits_for_warmup_before_adapting() {
        let start = Instant::now();
        let config = QualityConfig {
            warmup: Duration::from_secs(3),
            window: Duration::from_secs(1),
            ..config()
        };
        let mut quality = AdaptiveQuality::with_config(9, start, config);
        let mut now = start;
        let mut changes = Vec::new();
        for _ in 0..40 {
            now += Duration::from_millis(200);
            let elapsed = now.saturating_duration_since(start);
            if let Some(level) = quality.observe(now, 150_000) {
                changes.push((elapsed, level));
            }
        }
        let first = changes.first().expect("slow link should adapt");
        assert_eq!(first.1, 8);
        assert!(first.0 >= Duration::from_secs(3), "adapted during warmup");
    }

    #[test]
    fn stays_above_minimum_quality() {
        let start = Instant::now();
        let mut quality = AdaptiveQuality::with_config(4, start, config());
        let mut now = start;
        let mut changes = Vec::new();
        for _ in 0..40 {
            now += Duration::from_millis(200);
            if let Some(level) = quality.observe(now, 200_000) {
                changes.push(level);
            }
        }
        assert_eq!(changes, vec![3, 2]);
        assert_eq!(quality.current(), 2);
    }
}
