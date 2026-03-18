// MongoDB initialization — runs once on first container start
// Executed as the mongo entrypoint init script

const db = db.getSiblingDB('ecommerce');

// ── Products ──────────────────────────────────────────────────────────────────
db.createCollection('products');

// Unique index on SKU — enforced at DB level to complement app-level validation
db.products.createIndex({ sku: 1 }, { unique: true, name: 'idx_products_sku_unique' });

// Compound index for common list queries (sort by price, filter by name)
db.products.createIndex({ name: 1, sku: 1 }, { name: 'idx_products_name_sku' });

// Full-text index for search endpoint
db.products.createIndex(
  { name: 'text', sku: 'text' },
  { name: 'idx_products_text_search', weights: { name: 10, sku: 5 } }
);

// ── Orders ────────────────────────────────────────────────────────────────────
db.createCollection('orders');

// Index on createdAt for reporting aggregation (total last month)
db.orders.createIndex({ createdAt: 1 }, { name: 'idx_orders_created_at' });

// Index on total for highest-order report
db.orders.createIndex({ total: -1 }, { name: 'idx_orders_total_desc' });

print('MongoDB indexes initialized.');
