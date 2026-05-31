#[cfg(feature = "named-prepared-statements")]
use crate::client::InnerClient;
#[cfg(feature = "named-prepared-statements")]
use crate::codec::FrontendMessage;
#[cfg(feature = "named-prepared-statements")]
use crate::connection::RequestMessages;
use crate::types::Type;
#[cfg(feature = "named-prepared-statements")]
use postgres_protocol::message::frontend;
use std::sync::Arc;
#[cfg(feature = "named-prepared-statements")]
use std::sync::Weak;

struct StatementInner {
    #[cfg(feature = "named-prepared-statements")]
    client: Weak<InnerClient>,
    #[cfg(feature = "named-prepared-statements")]
    name: String,
    params: Vec<Type>,
    columns: Vec<Column>,
}

#[cfg(feature = "named-prepared-statements")]
impl Drop for StatementInner {
    fn drop(&mut self) {
        if self.name.is_empty() {
            // Unnamed statements don't need to be closed
            return;
        }
        if let Some(client) = self.client.upgrade() {
            let buf = client.with_buf(|buf| {
                frontend::close(b'S', &self.name, buf).unwrap();
                frontend::sync(buf);
                buf.split().freeze()
            });
            let _ = client.send(RequestMessages::Single(FrontendMessage::Raw(buf)));
        }
    }
}

/// A prepared statement.
///
/// Prepared statements can only be used with the connection that created them.
#[derive(Clone)]
pub struct Statement(Arc<StatementInner>);

impl Statement {
    #[cfg(feature = "named-prepared-statements")]
    pub(crate) fn new(
        inner: &Arc<InnerClient>,
        name: String,
        params: Vec<Type>,
        columns: Vec<Column>,
    ) -> Statement {
        Statement(Arc::new(StatementInner {
            client: Arc::downgrade(inner),
            name,
            params,
            columns,
        }))
    }

    pub(crate) fn unnamed(params: Vec<Type>, columns: Vec<Column>) -> Statement {
        Statement(Arc::new(StatementInner {
            #[cfg(feature = "named-prepared-statements")]
            client: Weak::new(),
            #[cfg(feature = "named-prepared-statements")]
            name: String::new(),
            params,
            columns,
        }))
    }

    #[cfg(feature = "named-prepared-statements")]
    pub(crate) fn name(&self) -> &str {
        &self.0.name
    }

    /// Returns the expected types of the statement's parameters.
    pub fn params(&self) -> &[Type] {
        &self.0.params
    }

    /// Returns information about the columns returned when the statement is queried.
    pub fn columns(&self) -> &[Column] {
        &self.0.columns
    }
}

impl std::fmt::Debug for Statement {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> Result<(), std::fmt::Error> {
        let mut ds = f.debug_struct("Statement");

        #[cfg(feature = "named-prepared-statements")]
        ds.field("name", &self.0.name);

        ds.field("params", &self.0.params)
            .field("columns", &self.0.columns)
            .finish_non_exhaustive()
    }
}

/// Information about a column of a query.
#[derive(Debug)]
pub struct Column {
    pub(crate) name: String,
    pub(crate) table_oid: Option<u32>,
    pub(crate) column_id: Option<i16>,
    pub(crate) type_modifier: i32,
    pub(crate) r#type: Type,
}

impl Column {
    /// Returns the name of the column.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Returns the OID of the underlying database table.
    pub fn table_oid(&self) -> Option<u32> {
        self.table_oid
    }

    /// Return the column ID within the underlying database table.
    pub fn column_id(&self) -> Option<i16> {
        self.column_id
    }

    /// Return the type modifier
    pub fn type_modifier(&self) -> i32 {
        self.type_modifier
    }

    /// Returns the type of the column.
    pub fn type_(&self) -> &Type {
        &self.r#type
    }
}
