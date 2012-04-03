/*
	qWat - QGIS Water Module
	
	SQL file :: nodes
*/

BEGIN;

/* CREATE TABLE */
DROP TABLE IF EXISTS distribution.nodes CASCADE;
CREATE TABLE distribution.nodes (id serial NOT NULL);
ALTER TABLE distribution.nodes ADD COLUMN  _type        VARCHAR(20) DEFAULT '';
ALTER TABLE distribution.nodes ADD COLUMN  _orientation FLOAT       DEFAULT 0;
ALTER TABLE distribution.nodes ADD COLUMN  _schema_view BOOLEAN     DEFAULT False;
SELECT AddGeometryColumn('distribution', 'nodes', 'wkb_geometry', 21781, 'POINT', 2);
SELECT setval('distribution.nodes_id_seq', 100, true);
/* ADD CONSTRAINTS */
/* primary key */
ALTER TABLE distribution.nodes ADD CONSTRAINT nodes_pkey PRIMARY KEY (id);
/* GIST index*/
CREATE INDEX nodes_geoidx ON distribution.nodes USING GIST ( wkb_geometry );
/* Comment */
COMMENT ON TABLE distribution.nodes IS 'Nodes. Type:If three pipes or more arrives at the node: three. If one pipe: one. If two: depends on characteristics of pipes: two_same (everything same), two_year (year is different), two_material (and year is/are different), two_diameter (and material/year are different). Orientation is calculated if two pipes arrives to place the symbol in theright direction.';

/* node type: end, intersection, year, material, diameter */


CREATE OR REPLACE FUNCTION distribution.node_get_id(geometry) RETURNS integer AS '
	DECLARE
		point ALIAS for $1;
		node_id integer;
		distance_threshold double precision := 0.000001;
	BEGIN
		SELECT id FROM distribution.nodes WHERE ST_Distance(point,wkb_geometry)<distance_threshold LIMIT 1 INTO node_id;
		IF node_id IS NULL THEN
			INSERT INTO distribution.nodes (wkb_geometry) VALUES (point);
		END IF;
		SELECT id FROM distribution.nodes WHERE ST_Distance(point,wkb_geometry)<distance_threshold LIMIT 1 INTO node_id;
		RETURN node_id;	
	END;
' LANGUAGE 'plpgsql';
COMMENT ON FUNCTION distribution.node_get_id(geometry) IS 'Returns the node for a given geometry (point). If node does not exist, it is created.';


/* 
To reset all pipes nodes
sige -c "
UPDATE distribution.pipes SET id_node_a = distribution.node_get_id(ST_StartPoint(wkb_geometry)),
                              id_node_b = distribution.node_get_id(ST_EndPoint(  wkb_geometry));
"
*/

CREATE OR REPLACE FUNCTION distribution.node_update_type(integer) RETURNS void AS '
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
		SELECT COUNT(pipes_view.id) AS count , bool_or(pipes_view._schema_view) AS schema_view INTO grouped FROM distribution.pipes_view WHERE id_node_a = node_id OR id_node_b = node_id;
		IF grouped.count = 1 THEN
			type := ''one'';
		ELSEIF grouped.count = 2 THEN
			FOR pipeitem IN (
				SELECT year,_material_longname,_material_diameter,ST_PointN(wkb_geometry,2)                          AS point_1 , ST_StartPoint(wkb_geometry) AS point_2 FROM distribution.pipes_view WHERE id_node_a = node_id
				UNION
				SELECT year,_material_longname,_material_diameter,ST_PointN(wkb_geometry,ST_NPoints(wkb_geometry)-1) AS point_1 , ST_EndPoint(  wkb_geometry) AS point_2 FROM distribution.pipes_view WHERE id_node_b = node_id
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
		ELSE
			type := ''three'';
		END IF;
		UPDATE distribution.nodes SET _type = type, _orientation = orientation, _schema_view = grouped.schema_view WHERE id = node_id;
		/*RAISE NOTICE ''% %'' , node_id , orientation;*/
	END;
' LANGUAGE 'plpgsql';
COMMENT ON FUNCTION distribution.node_update_type(integer) IS 'Set the orientation and type for a node. If three pipes arrives at the node: intersection. If one pipe: end. If two: depends on characteristics of pipes: year (is different), material (and year), diameter(and material/year)';



CREATE OR REPLACE FUNCTION distribution.node_update_all() RETURNS void AS '
	DECLARE
		node record;
	BEGIN
		FOR node IN SELECT id FROM distribution.nodes ORDER BY id LOOP
			PERFORM distribution.node_update_type(node.id);
		END LOOP;
	END;
' LANGUAGE 'plpgsql';
COMMENT ON FUNCTION distribution.node_update_all() IS 'Set the type and orientation for all nodes. If three pipes arrives at the node: intersection. If one pipe: end. If two: depends on characteristics of pipes: year (is different), material (and year), diameter(and material/year)';
         
COMMIT;

