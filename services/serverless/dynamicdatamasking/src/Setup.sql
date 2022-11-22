IF NOT EXISTS (SELECT * FROM sys.schemas WHERE [name] ='utils')
	EXEC('CREATE SCHEMA utils AUTHORIZATION dbo;')
GO

IF NOT EXISTS (SELECT * FROM sys.schemas WHERE [name] ='masked')
	EXEC('CREATE SCHEMA [masked] AUTHORIZATION dbo;')
GO

CREATE OR ALTER PROCEDURE utils.usp_CreateOrRefreshMaskedView
 @full_view_name NVARCHAR(255),
 @column_list_to_mask NVARCHAR(MAX),
 @masked_schema_name NVARCHAR(255) = 'masked'
 AS
 BEGIN
  DECLARE @dataMaskigCondition VARCHAR(MAX) = 'HAS_PERMS_BY_NAME(''{schema_name}'', ''SCHEMA'',''UNMASK'') <> 1';
DECLARE @stringTypeDataMasking VARCHAR(MAX) = 'CAST(IIF(DATALENGTH([{column_title}]) <=2, ''X''+REPLICATE(''x'',DATALENGTH([{column_title}])-1),SUBSTRING([{column_title}],1,1)+ REPLICATE(''x'',DATALENGTH([{column_title}])-2) + SUBSTRING([{column_title}],DATALENGTH([{column_title}])-1,1) ) AS {column_datatype})';
DECLARE @numericTypeDataMasking VARCHAR(MAX) = 'CAST(0 AS {s})';
DECLARE @datetimeTypeDataMasking VARCHAR(MAX) = 'CAST(''2000-01-01'' AS {column_datatype})';
DECLARE @booleanTypeDataMasking VARCHAR(MAX) = 'CAST(0 AS BIT)';

DECLARE @recreate_view_template NVARCHAR(MAX) = CONCAT(N'CREATE OR ALTER VIEW {new_view_name} AS SELECT {column_list_masked} FROM ',@full_view_name);

DECLARE @dataMaskingFullCondition VARCHAR(MAX);
DECLARE @view_openrowset_statement NVARCHAR(MAX);
DECLARE @column_list_masked NVARCHAR(MAX);
DECLARE @newViewName VARCHAR(MAX);



DECLARE @ds_info_query NVARCHAR(1000) = CONCAT (
		'SELECT TOP 0 * FROM '
		,@full_view_name
		);

SELECT 
		@newViewName =CONCAT('[',@masked_schema_name,'].[',o.[name],']')
	FROM sys.objects o
	JOIN sys.sql_modules m ON m.object_id = o.object_id
	JOIN sys.schemas AS s ON s.schema_id = o.schema_id
	WHERE o.[type] = 'V' AND o.object_id = object_id(@full_view_name);

SET @recreate_view_template = REPLACE(@recreate_view_template,'{new_view_name}',@newViewName);

IF OBJECT_ID('tempdb..#type_ds_schema') IS NOT NULL
	DROP TABLE #type_ds_schema;

CREATE TABLE #type_ds_schema (
	is_hidden BIT NOT NULL
	,column_ordinal INT NOT NULL
	,[name] SYSNAME NULL
	,is_nullable BIT NOT NULL
	,system_type_id INT NOT NULL
	,system_type_name NVARCHAR(256) NULL
	,max_length SMALLINT NOT NULL
	,[precision] TINYINT NOT NULL
	,scale TINYINT NOT NULL
	,collation_name SYSNAME NULL
	,user_type_id INT NULL
	,user_type_database SYSNAME NULL
	,user_type_schema SYSNAME NULL
	,user_type_name SYSNAME NULL
	,assembly_qualified_type_name NVARCHAR(4000)
	,xml_collection_id INT NULL
	,xml_collection_database SYSNAME NULL
	,xml_collection_schema SYSNAME NULL
	,xml_collection_name SYSNAME NULL
	,is_xml_document BIT NOT NULL
	,is_case_sensitive BIT NOT NULL
	,is_fixed_length_clr_type BIT NOT NULL
	,source_server SYSNAME NULL
	,source_database SYSNAME NULL
	,source_schema SYSNAME NULL
	,source_table SYSNAME NULL
	,source_column SYSNAME NULL
	,is_identity_column BIT NULL
	,is_part_of_unique_key BIT NULL
	,is_updateable BIT NULL
	,is_computed_column BIT NULL
	,is_sparse_column_set BIT NULL
	,ordinal_in_order_by_list SMALLINT NULL
	,order_by_list_length SMALLINT NULL
	,order_by_is_descending SMALLINT NULL
	,tds_type_id INT NOT NULL
	,tds_length INT NOT NULL
	,tds_collation_id INT NULL
	,tds_collation_sort_id TINYINT NULL
	);



SET @dataMaskingFullCondition = REPLACE(@dataMaskigCondition,'{schema_name}', @masked_schema_name);


---extract column info
INSERT #type_ds_schema
EXEC sys.sp_describe_first_result_set @ds_info_query;


--find columns to mask
WITH ColumnsToMask
AS (
	SELECT [value] AS column_name
		,CAST(1 AS BIT) mask
	FROM STRING_SPLIT(@column_list_to_mask, ',')
	)
	,ColumnsInfo
AS (
	SELECT s.name AS column_name
		,s.system_type_id
		,s.system_type_name
		,s.precision
		,s.collation_name
		,s.column_ordinal
		,m.mask
	FROM #type_ds_schema AS s
	LEFT JOIN ColumnsToMask AS m ON m.column_name = s.[name]
	)
	,MaskedColumns
AS (
	SELECT CASE 
			WHEN mask = 0
				THEN column_name
			WHEN mask = 1
				THEN CONCAT (
						'IIF('
						,@dataMaskingFullCondition
						,',', CASE 
							WHEN system_type_id IN (
									35
									,99
									,167
									,175
									,231
									,239
									,231
									) --string
								THEN REPLACE(REPLACE(@stringTypeDataMasking, '{column_title}', column_name), '{column_datatype}', system_type_name)
							WHEN system_type_id IN (
									48
									,52
									,56
									,59
									,60
									,62
									,106
									,108
									,122
									,127
									) --numeric
								THEN REPLACE(@numericTypeDataMasking, '{column_datatype}', system_type_name)
							WHEN system_type_id IN (104) --bit
								THEN REPLACE(@booleanTypeDataMasking, '{column_datatype}', system_type_name)
							WHEN system_type_id IN (
									40
									,42
									,61
									,189
									) --date
								THEN REPLACE(@datetimeTypeDataMasking, '{column_datatype}', system_type_name)
							ELSE column_name
							END
						,',['
						,column_name
						,']) AS ['
						,column_name
						,']'
						)
			ELSE column_name
			END AS column_name
		,column_ordinal
		,mask
	FROM ColumnsInfo
	)

SELECT @column_list_masked = STRING_AGG(CAST(column_name AS NVARCHAR(MAX)), ',') WITHIN
GROUP (
		ORDER BY column_ordinal
		)
FROM MaskedColumns;

SET @recreate_view_template = REPLACE(@recreate_view_template,'{column_list_masked}',@column_list_masked);
--SELECT @recreate_view_template;

EXEC sp_executesql @recreate_view_template;
 END