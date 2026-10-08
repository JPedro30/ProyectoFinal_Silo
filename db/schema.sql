-- ============================================================
--  Gestión de silos y movimientos de grano - PostgreSQL
--  Pesos y cantidades en kilogramos.
-- ============================================================

-- ---------- Tipos enumerados ----------
CREATE TYPE rol_usuario     AS ENUM ('AD', 'TR', 'EM');  -- Admin, Trabajador, Empresa
CREATE TYPE tipo_movimiento AS ENUM ('E', 'S');          -- Entrada, Salida

-- ---------- EMPRESAS ----------
CREATE TABLE empresas (
    id_empresa  SERIAL PRIMARY KEY,
    nombre      VARCHAR(150) NOT NULL,
    cif         VARCHAR(9)   NOT NULL UNIQUE
);

-- ---------- USUARIOS ----------
CREATE TABLE usuarios (
    id_usuario      SERIAL PRIMARY KEY,
    id_empresa      INT NULL REFERENCES empresas(id_empresa),
    rol             rol_usuario  NOT NULL,
    username        VARCHAR(150) NOT NULL UNIQUE,
    email           VARCHAR(150) NOT NULL UNIQUE,
    nombre          VARCHAR(150) NOT NULL,
    contrasena_hash VARCHAR(255) NOT NULL,
    -- EM obligatoriamente con empresa; AD y TR sin empresa
    CONSTRAINT ck_usuario_rol_empresa CHECK (
        (rol = 'EM' AND id_empresa IS NOT NULL) OR
        (rol IN ('AD', 'TR') AND id_empresa IS NULL)
    )
);

-- ---------- SILOS ----------
CREATE TABLE silos (
    id_silo         SERIAL PRIMARY KEY,
    id_empresa      INT NULL REFERENCES empresas(id_empresa),
    habilitado      BOOLEAN NOT NULL DEFAULT TRUE,
    capacidad_max   NUMERIC(10,2) NOT NULL CHECK (capacidad_max > 0),
    cantidad_actual NUMERIC(10,2) NOT NULL DEFAULT 0,
    CONSTRAINT ck_silo_capacidad CHECK (cantidad_actual >= 0 AND cantidad_actual <= capacidad_max)
);

-- ---------- MATERIALES ----------
CREATE TABLE materiales (
    id_material    SERIAL PRIMARY KEY,
    tipo_general   VARCHAR(80)  NOT NULL,
    tipo_especifico VARCHAR(80) NOT NULL,
    nombre         VARCHAR(150) NOT NULL
);

-- ---------- TRANSPORTISTAS (conductor + vehículo) ----------
CREATE TABLE transportistas (
    id_vehiculo       SERIAL PRIMARY KEY,
    nombre            VARCHAR(150) NOT NULL,
    dni               VARCHAR(9)   NOT NULL UNIQUE,
    matricula_camion  VARCHAR(80)  NOT NULL,
    matricula_remolque VARCHAR(80) NULL
);

-- ---------- MOVIMIENTOS ----------
CREATE TABLE movimientos (
    id_movimiento      SERIAL PRIMARY KEY,
    id_trabajador      INT NOT NULL REFERENCES usuarios(id_usuario),
    id_empresa         INT NOT NULL REFERENCES empresas(id_empresa),
    id_silo            INT NOT NULL REFERENCES silos(id_silo),
    id_material        INT NOT NULL REFERENCES materiales(id_material),
    id_vehiculo        INT NOT NULL REFERENCES transportistas(id_vehiculo),
    tipo_movimiento    tipo_movimiento NOT NULL,
    fecha_hora_entrada TIMESTAMP NOT NULL,
    peso_entrada       NUMERIC(10,2) NOT NULL CHECK (peso_entrada > 0),
    fecha_hora_salida  TIMESTAMP NOT NULL,
    peso_salida        NUMERIC(10,2) NOT NULL CHECK (peso_salida > 0),
    cantidad           NUMERIC(10,2) GENERATED ALWAYS AS (ABS(peso_entrada - peso_salida)) STORED,
    humedad_material   DECIMAL(5,2) NULL,
    proteina           DECIMAL(5,2) NULL,
    humedad_ambiental  DECIMAL(5,2) NULL,   -- API meteorológica
    precipitacion      BOOLEAN      NULL,   -- API meteorológica
    CONSTRAINT ck_mov_fechas   CHECK (fecha_hora_salida > fecha_hora_entrada),
    CONSTRAINT ck_mov_cantidad CHECK (peso_entrada <> peso_salida)
);

CREATE INDEX idx_mov_empresa ON movimientos(id_empresa, fecha_hora_entrada);
CREATE INDEX idx_mov_silo    ON movimientos(id_silo, fecha_hora_entrada);

-- ============================================================
--  TRIGGERS DE INTEGRIDAD
-- ============================================================

-- 1) Validar el movimiento antes de insertarlo
CREATE OR REPLACE FUNCTION fn_validar_movimiento() RETURNS TRIGGER AS $$
DECLARE
    v_rol        rol_usuario;
    v_silo_emp   INT;
    v_habilitado BOOLEAN;
BEGIN
    -- El que registra debe ser trabajador (o admin), nunca una empresa
    SELECT rol INTO v_rol FROM usuarios WHERE id_usuario = NEW.id_trabajador;
    IF v_rol NOT IN ('TR', 'AD') THEN
        RAISE EXCEPTION 'El usuario % no puede registrar movimientos (rol %)', NEW.id_trabajador, v_rol;
    END IF;

    -- El silo debe pertenecer a la empresa del movimiento y estar habilitado
    SELECT id_empresa, habilitado INTO v_silo_emp, v_habilitado
    FROM silos WHERE id_silo = NEW.id_silo;

    IF v_silo_emp IS DISTINCT FROM NEW.id_empresa THEN
        RAISE EXCEPTION 'El silo % no pertenece a la empresa %', NEW.id_silo, NEW.id_empresa;
    END IF;
    IF NOT v_habilitado THEN
        RAISE EXCEPTION 'El silo % está deshabilitado', NEW.id_silo;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validar_movimiento
BEFORE INSERT ON movimientos
FOR EACH ROW EXECUTE FUNCTION fn_validar_movimiento();

-- 2) Actualizar la cantidad del silo tras registrar el movimiento
--    (si supera la capacidad o baja de 0, el CHECK del silo aborta toda la transacción)
CREATE OR REPLACE FUNCTION fn_actualizar_silo() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.tipo_movimiento = 'E' THEN
        UPDATE silos SET cantidad_actual = cantidad_actual + NEW.cantidad
        WHERE id_silo = NEW.id_silo;
    ELSE
        UPDATE silos SET cantidad_actual = cantidad_actual - NEW.cantidad
        WHERE id_silo = NEW.id_silo;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_actualizar_silo
AFTER INSERT ON movimientos
FOR EACH ROW EXECUTE FUNCTION fn_actualizar_silo();

-- 3) Un silo solo puede cambiar de empresa si está vacío
CREATE OR REPLACE FUNCTION fn_reasignar_silo() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.id_empresa IS DISTINCT FROM OLD.id_empresa AND OLD.cantidad_actual > 0 THEN
        RAISE EXCEPTION 'El silo % no está vacío (% kg); no se puede reasignar', OLD.id_silo, OLD.cantidad_actual;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reasignar_silo
BEFORE UPDATE OF id_empresa ON silos
FOR EACH ROW EXECUTE FUNCTION fn_reasignar_silo();

-- 4) Los movimientos no se borran, y solo pueden completarse los datos de la API
--    meteorológica (por si hay que reintentar la consulta más tarde)
CREATE OR REPLACE FUNCTION fn_movimiento_inmutable() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Los movimientos no se pueden eliminar';
    END IF;

    IF (NEW.id_movimiento, NEW.id_trabajador, NEW.id_empresa, NEW.id_silo, NEW.id_material,
        NEW.id_vehiculo, NEW.tipo_movimiento, NEW.fecha_hora_entrada, NEW.peso_entrada,
        NEW.fecha_hora_salida, NEW.peso_salida, NEW.humedad_material, NEW.proteina)
       IS DISTINCT FROM
       (OLD.id_movimiento, OLD.id_trabajador, OLD.id_empresa, OLD.id_silo, OLD.id_material,
        OLD.id_vehiculo, OLD.tipo_movimiento, OLD.fecha_hora_entrada, OLD.peso_entrada,
        OLD.fecha_hora_salida, OLD.peso_salida, OLD.humedad_material, OLD.proteina) THEN
        RAISE EXCEPTION 'Solo se pueden actualizar humedad_ambiental y precipitacion';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_movimiento_inmutable
BEFORE UPDATE OR DELETE ON movimientos
FOR EACH ROW EXECUTE FUNCTION fn_movimiento_inmutable();
