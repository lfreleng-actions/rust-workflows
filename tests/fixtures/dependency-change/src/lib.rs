// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 The Linux Foundation

//! Fixture crate for the verify lane's dependency-change leg.

/// Returns the sum of two numbers.
pub fn add(left: u64, right: u64) -> u64 {
    left + right
}

#[cfg(test)]
mod tests {
    use super::add;

    #[test]
    fn adds() {
        assert_eq!(add(2, 2), 4);
    }
}
