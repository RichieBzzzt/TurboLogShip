CREATE TABLE [TurboLogShipping].[TurboLogShippingLogging]
(
	[Id] INT NOT NULL IDENTITY (1,1) PRIMARY KEY
	,TimeOfMessage DATETIME2
	,LogShippedDatabase SYSNAME
	,RestoreJobName SYSNAME
	,[Message] NVARCHAR (512)  
)
