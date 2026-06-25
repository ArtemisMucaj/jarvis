//! Milestone 6: retry bookkeeping.
//!
//! When a tool call fails validation, the guardrail loop appends a corrective
//! nudge and asks the backend again, up to a budget. [`ErrorTracker`] holds that
//! budget; the nudge is delivered as a plain `user` message — universal across
//! backends and, unlike a `tool` message, needing no dangling `tool_call_id`.

use serde_json::{json, Value};

/// Tracks how many corrective retries remain in a single guardrail loop.
#[derive(Debug)]
pub struct ErrorTracker {
    max_retries: u32,
    attempts: u32,
}

impl ErrorTracker {
    pub fn new(max_retries: u32) -> Self {
        Self {
            max_retries,
            attempts: 0,
        }
    }

    /// Whether another retry is still within budget.
    pub fn can_retry(&self) -> bool {
        self.attempts < self.max_retries
    }

    /// Record that a retry is being issued.
    pub fn record_retry(&mut self) {
        self.attempts += 1;
    }

    /// Number of retries issued so far.
    pub fn attempts(&self) -> u32 {
        self.attempts
    }
}

/// Build the corrective nudge as a `user` message to append to the conversation.
pub fn nudge_message(nudge: &str) -> Value {
    json!({ "role": "user", "content": nudge })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn budget_is_respected() {
        let mut t = ErrorTracker::new(2);
        assert!(t.can_retry());
        t.record_retry();
        assert!(t.can_retry());
        t.record_retry();
        assert!(!t.can_retry());
        assert_eq!(t.attempts(), 2);
    }

    #[test]
    fn zero_budget_never_retries() {
        let t = ErrorTracker::new(0);
        assert!(!t.can_retry());
    }

    #[test]
    fn nudge_is_a_user_message() {
        let m = nudge_message("try again");
        assert_eq!(m["role"], "user");
        assert_eq!(m["content"], "try again");
    }
}
