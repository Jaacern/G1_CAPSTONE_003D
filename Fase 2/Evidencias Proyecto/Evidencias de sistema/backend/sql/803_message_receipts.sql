CREATE TABLE message_receipts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id UUID NOT NULL REFERENCES messages(id) ON DELETE RESTRICT,
    recipient_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    delivered_at TIMESTAMP WITH TIME ZONE,
    read_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT uq_message_receipts_message_recipient UNIQUE (message_id, recipient_id)
);

COMMENT ON TABLE message_receipts IS 'Estado de entrega y lectura de mensajes por cada destinatario del círculo de cuidado.';
COMMENT ON COLUMN message_receipts.id IS 'Identificador único del acuse de recibo.';
COMMENT ON COLUMN message_receipts.message_id IS 'Mensaje asociado al acuse.';
COMMENT ON COLUMN message_receipts.recipient_id IS 'Usuario destinatario del mensaje.';
COMMENT ON COLUMN message_receipts.delivered_at IS 'Fecha y hora en que el mensaje fue entregado al dispositivo.';
COMMENT ON COLUMN message_receipts.read_at IS 'Fecha y hora en que el mensaje fue leído por el usuario.';
COMMENT ON COLUMN message_receipts.created_at IS 'Fecha y hora de creación del registro.';

CREATE INDEX ix_message_receipts_unread 
ON message_receipts(recipient_id) WHERE read_at IS NULL;

CREATE INDEX ix_message_receipts_undelivered 
ON message_receipts(recipient_id) WHERE delivered_at IS NULL;