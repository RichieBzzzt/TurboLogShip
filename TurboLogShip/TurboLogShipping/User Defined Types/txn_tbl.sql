CREATE TYPE [TurboLogShipping].[txn_tbl] AS TABLE (
    [subdirectory] NVARCHAR (1024) NULL,
    [DEPTH]        INT             NULL,
    [isfile]       BIT             NULL,
    [BackupInt]    BIGINT          NULL);

