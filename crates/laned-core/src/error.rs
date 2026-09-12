/// Everything the shell can be told went wrong. Deliberately small: the shell's
/// only sensible responses are "show the message" and "carry on with the last
/// good snapshot".
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    /// The ledger could not be read or written. The strip on screen is still
    /// valid; the mutation did not happen.
    #[error("ledger: {message}")]
    Ledger { message: String },

    /// A lane or pane id that is not in the ledger. Usually a stale id held by
    /// the shell across a mutation it missed.
    #[error("no such {kind}: {id}")]
    NotFound { kind: String, id: String },

    /// The mutation is not allowed by the model, e.g. moving a lane relative to
    /// itself or nesting a lane inside a pane.
    #[error("invalid: {message}")]
    Invalid { message: String },
}

impl From<rusqlite::Error> for CoreError {
    fn from(e: rusqlite::Error) -> Self {
        CoreError::Ledger { message: e.to_string() }
    }
}

pub type Result<T> = std::result::Result<T, CoreError>;
