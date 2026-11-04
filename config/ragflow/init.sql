-- RAGFlow metadata database bootstrap (verbatim from the upstream
-- docker/init.sql of infiniflow/ragflow v1.0.0-rc3). Mounted into
-- ragflow-mysql via --init-file on first initialization only.
CREATE DATABASE IF NOT EXISTS rag_flow;
USE rag_flow;
