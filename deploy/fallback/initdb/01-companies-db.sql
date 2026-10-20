-- The API opens a second connection for CNPJ lookups (/company/*).
-- The fallback does not load CNPJ data; an empty database keeps the API healthy.
CREATE DATABASE companies OWNER queridodiario;
