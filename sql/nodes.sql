/*
	qWat - QGIS Water Module
	
	SQL file :: nodes
*/

BEGIN;

/* CREATE TABLE */
DROP TABLE IF EXISTS distribution.nodes CASCADE;
CREATE TABLE distribution.nodes (id serial NOT NULL);
COMMENT ON TABLE distribution.nodes IS 'Nodes. Type:If three pipes or more arrives at the node: three. If one pipe: one. If two: depends on characteristics of pipes: two_same (everything same), two_year (year is different), two_material (and year is/are different), two_diameter (and material/year are different). Orientation is calculated if two pipes arrives to place the symbol in theright direction.';

ALTER TABLE distribution.nodes ADD COLUMN  altitude_dtm       DECIMAL(10,3)              ;
ALTER TABLE distribution.nodes ADD COLUMN  altitude_real      DECIMAL(10,3)              ;
ALTER TABLE distribution.nodes ADD COLUMN  _type              VARCHAR(20)   DEFAULT NULL ;
ALTER TABLE distribution.nodes ADD COLUMN  _orientation       FLOAT         DEFAULT 0    ;
ALTER TABLE distribution.nodes ADD COLUMN  _schema_view       BOOLEAN       DEFAULT False;
ALTER TABLE distribution.nodes ADD COLUMN  _status_active     BOOLEAN       DEFAULT False;
ALTER TABLE distribution.nodes ADD COLUMN  _altitude_uptodate BOOLEAN       DEFAULT False;
SELECT AddGeometryColumn('distribution', 'nodes', 'geometry', 21781, 'POINT', 2)  ;
SELECT setval('distribution.nodes_id_seq', 40000, true);
/* ADD CONSTRAINTS */
/* primary key */
ALTER TABLE distribution.nodes ADD CONSTRAINT nodes_pkey PRIMARY KEY (id);
/* GIST index*/
CREATE INDEX nodes_geoidx ON distribution.nodes USING GIST ( geometry );


/*----------------!!!---!!!----------------*/
/* Trigger for geometry */
CREATE OR REPLACE FUNCTION distribution.nodes_geom() RETURNS trigger AS ' 
	BEGIN
		UPDATE distribution.nodes SET
			_altitude_uptodate = NULL
		WHERE id = NEW.id ;
		RETURN NEW;
	END;
' LANGUAGE 'plpgsql';
COMMENT ON FUNCTION distribution.nodes_geom() IS 'Fcn/Trigger: set uptodate to false for altitude when geometry changes.';

CREATE TRIGGER nodes_geom_trigger 
	AFTER INSERT OR UPDATE OF geometry ON distribution.nodes
		FOR EACH ROW
		EXECUTE PROCEDURE distribution.nodes_geom();
COMMENT ON TRIGGER nodes_geom_trigger ON distribution.nodes IS 'Trigger: uset uptodate to false for altitude when geometry changes.';



/* nodes altitude */
CREATE OR REPLACE FUNCTION distribution.nodes_altitude() RETURNS void AS '
	DECLARE
		altitude double precision;
		nodeitem RECORD;
	BEGIN
		FOR nodeitem IN SELECT id,geometry FROM distribution.nodes WHERE _altitude_uptodate IS NOT TRUE ORDER BY id LOOP
			RAISE NOTICE ''%'', nodeitem.id;
			SELECT altitude.altitude(nodeitem.geometry) INTO altitude;
			UPDATE distribution.nodes SET altitude_dtm = altitude, _altitude_uptodate = TRUE WHERE id = nodeitem.id;
		END LOOP;
	END
' LANGUAGE 'plpgsql';
COMMENT ON FUNCTION distribution.nodes_altitude() IS 'Fill the altitude of the nodes.';



/* TODO: prevent node deletion if pipes are connected */


/* node type: end, intersection, year, material, diameter */

CREATE OR REPLACE FUNCTION distribution.node_get_id(geometry,boolean) RETURNS integer AS '
	DECLARE
		point ALIAS for $1;
		place_node ALIAS for $2;
		node_id integer;
	BEGIN
		SELECT id FROM distribution.nodes WHERE ST_OrderingEquals(point,geometry) IS TRUE LIMIT 1 INTO node_id;
		IF node_id IS NULL AND place_node IS TRUE THEN
			INSERT INTO distribution.nodes (geometry) VALUES (point);
			SELECT id FROM distribution.nodes WHERE ST_OrderingEquals(point,geometry) IS TRUE LIMIT 1 INTO node_id;
		END IF;
		RETURN node_id;	
	END;
' LANGUAGE 'plpgsql';
COMMENT ON FUNCTION distribution.node_get_id(geometry,boolean) IS 'Returns the node for a given geometry (point). If node does not exist, it is created.';



/* To reset all pipes nodes */
/*
UPDATE distribution.pipes SET id_node_a = distribution.node_get_id(ST_StartPoint(geometry,true)),
                              id_node_b = distribution.node_get_id(ST_EndPoint(  geometry,true));
*/


CREATE OR REPLACE FUNCTION distribution.node_type(integer) RETURNS void AS '
	DECLARE
		node_id     ALIAS FOR $1         ;
		pipeitem    RECORD               ;
		grouped     RECORD               ;
		Tyear       INTEGER              ;
		Tmaterial   VARCHAR(30)          ;
		Tdiameter   VARCHAR(10)          ;
		i           INTEGER          := 0;
		type        VARCHAR(20)          ;
		ori1        DOUBLE PRECISION := 0;
		ori2        DOUBLE PRECISION := 0;
		orientation FLOAT            := 0;
	BEGIN
		SELECT 
			COUNT(pipes_view.id)               AS count         ,
			bool_or(pipes_view._schema_view)   AS schema_view   ,
			bool_or(pipes_view._status_active) AS status_active
			INTO grouped 
			FROM distribution.pipes_view 
			WHERE (id_node_a = node_id OR id_node_b = node_id);
		IF grouped.count = 0 THEN
			RAISE NOTICE ''Delete node %'' , node_id ;
			DELETE FROM distribution.nodes WHERE id = node_id ;
		ELSEIF grouped.count = 1 THEN
			type := ''one'';
		ELSEIF grouped.count = 2 THEN
			FOR pipeitem IN (
				SELECT year,_material_longname,_material_diameter,ST_PointN(geometry,2)                      AS point_1 , ST_StartPoint(geometry) AS point_2 FROM distribution.pipes_view WHERE id_node_a = node_id
				UNION ALL
				SELECT year,_material_longname,_material_diameter,ST_PointN(geometry,ST_NPoints(geometry)-1) AS point_1 , ST_EndPoint(  geometry) AS point_2 FROM distribution.pipes_view WHERE id_node_b = node_id
			) LOOP
				IF i=0 THEN
					Tyear     := pipeitem.year;
					Tmaterial := pipeitem._material_longname;
					Tdiameter := pipeitem._material_diameter;
					i := 1;
					SELECT  ST_Azimuth(pipeitem.point_1,pipeitem.point_2) INTO ori1 ;
				ELSE
					type := ''two_same'';
					IF Tyear     != pipeitem.year               THEN type := ''two_year''    ; END IF;
					IF Tmaterial != pipeitem._material_longname THEN type := ''two_material''; END IF;
					IF Tdiameter != pipeitem._material_diameter THEN type := ''two_diameter''; END IF;
					SELECT ST_Azimuth(pipeitem.point_1,pipeitem.point_2) INTO ori2 ;
					SELECT degrees( ATAN2( (SIN(ori1)+SIN(ori2))/2 , (COS(ori1)+COS(ori2))/2 ) ) INTO orientation;
				END IF;
			END LOOP;
		ELSEIF grouped.count > 2 THEN
			type := ''three'';
		END IF;
		UPDATE distribution.nodes SET 
			_type          = type,
			_orientation   = orientation,
			_schema_view   = grouped.schema_view,
			_status_active = grouped.status_active
			WHERE id = node_id;
		/*RAISE NOTICE ''% %'' , node_id , orientation;*/
	END;
' LANGUAGE 'plpgsql';
COMMENT ON FUNCTION distribution.node_type(integer) IS 'Set the orientation and type for a node. If three pipes arrives at the node: intersection. If one pipe: end. If two: depends on characteristics of pipes: year (is different), material (and year), diameter(and material/year)';



CREATE OR REPLACE FUNCTION distribution.node_set_type() RETURNS void AS '
	DECLARE
		node record;
	BEGIN
		FOR node IN SELECT id FROM distribution.nodes WHERE _type IS NULL ORDER BY id LOOP
			PERFORM distribution.node_type(node.id);
		END LOOP;
	END;
' LANGUAGE 'plpgsql';
COMMENT ON FUNCTION distribution.node_set_type() IS 'Set the type and orientation for untyped nodes. If three pipes arrives at the node: intersection. If one pipe: end. If two: depends on characteristics of pipes: year (is different), material (and year), diameter(and material/year)';


CREATE OR REPLACE FUNCTION distribution.node_reset_all() RETURNS void AS '
	DECLARE
		node record;
	BEGIN
		UPDATE distribution.nodes SET _type = NULL;
		FOR node IN SELECT id FROM distribution.nodes ORDER BY id LOOP
			PERFORM distribution.node_type(node.id);
		END LOOP;
	END;
' LANGUAGE 'plpgsql';
COMMENT ON FUNCTION distribution.node_reset_all() IS 'Reset the type and orientation for all nodes. If three pipes arrives at the node: intersection. If one pipe: end. If two: depends on characteristics of pipes: year (is different), material (and year), diameter(and material/year)';
   
COMMIT;

