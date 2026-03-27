-- Add product_type column to client_bindings
ALTER TABLE client_bindings ADD COLUMN product_type VARCHAR(32) DEFAULT 'ghoststream';
