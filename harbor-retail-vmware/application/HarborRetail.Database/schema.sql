-- =============================================================================
-- Harbor Retail Database Schema
-- Database: HarborRetailDB
-- Platform: SQL Server 2019+
-- =============================================================================

USE [master];
GO

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'HarborRetailDB')
BEGIN
    CREATE DATABASE [HarborRetailDB]
    COLLATE SQL_Latin1_General_CP1_CI_AS;
END
GO

USE [HarborRetailDB];
GO

-- =============================================================================
-- Categories
-- =============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'dbo.Categories') AND type = 'U')
BEGIN
    CREATE TABLE dbo.Categories
    (
        CategoryId   INT            IDENTITY(1,1) NOT NULL,
        Name         NVARCHAR(100)  NOT NULL,
        Description  NVARCHAR(500)  NULL,
        IsActive     BIT            NOT NULL DEFAULT 1,
        CreatedDate  DATETIME2(7)   NOT NULL DEFAULT SYSUTCDATETIME(),
        ModifiedDate DATETIME2(7)   NULL,

        CONSTRAINT PK_Categories PRIMARY KEY CLUSTERED (CategoryId),
        CONSTRAINT UQ_Categories_Name UNIQUE (Name)
    );
END
GO

-- =============================================================================
-- Products
-- =============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'dbo.Products') AND type = 'U')
BEGIN
    CREATE TABLE dbo.Products
    (
        ProductId     INT            IDENTITY(1,1) NOT NULL,
        SKU           NVARCHAR(50)   NOT NULL,
        Name          NVARCHAR(200)  NOT NULL,
        Description   NVARCHAR(2000) NULL,
        Category      NVARCHAR(100)  NOT NULL,
        CategoryId    INT            NULL,
        UnitPrice     DECIMAL(18,2)  NOT NULL,
        StockQuantity INT            NOT NULL DEFAULT 0,
        ReorderLevel  INT            NOT NULL DEFAULT 10,
        IsActive      BIT            NOT NULL DEFAULT 1,
        ImageUrl      NVARCHAR(500)  NULL,
        Weight        DECIMAL(10,2)  NULL,
        CreatedDate   DATETIME2(7)   NOT NULL DEFAULT SYSUTCDATETIME(),
        ModifiedDate  DATETIME2(7)   NULL,

        CONSTRAINT PK_Products PRIMARY KEY CLUSTERED (ProductId),
        CONSTRAINT UQ_Products_SKU UNIQUE (SKU),
        CONSTRAINT FK_Products_Categories FOREIGN KEY (CategoryId)
            REFERENCES dbo.Categories (CategoryId),
        CONSTRAINT CK_Products_UnitPrice CHECK (UnitPrice >= 0),
        CONSTRAINT CK_Products_StockQuantity CHECK (StockQuantity >= 0)
    );

    CREATE NONCLUSTERED INDEX IX_Products_Category ON dbo.Products (Category);
    CREATE NONCLUSTERED INDEX IX_Products_SKU ON dbo.Products (SKU);
    CREATE NONCLUSTERED INDEX IX_Products_IsActive ON dbo.Products (IsActive) INCLUDE (Name, UnitPrice, StockQuantity);
END
GO

-- =============================================================================
-- Customers
-- =============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'dbo.Customers') AND type = 'U')
BEGIN
    CREATE TABLE dbo.Customers
    (
        CustomerId    INT            IDENTITY(1,1) NOT NULL,
        FirstName     NVARCHAR(100)  NOT NULL,
        LastName      NVARCHAR(100)  NOT NULL,
        Email         NVARCHAR(255)  NOT NULL,
        Phone         NVARCHAR(20)   NULL,
        AddressLine1  NVARCHAR(200)  NULL,
        AddressLine2  NVARCHAR(200)  NULL,
        City          NVARCHAR(100)  NULL,
        State         NVARCHAR(50)   NULL,
        ZipCode       NVARCHAR(10)   NULL,
        IsActive      BIT            NOT NULL DEFAULT 1,
        CreatedDate   DATETIME2(7)   NOT NULL DEFAULT SYSUTCDATETIME(),
        ModifiedDate  DATETIME2(7)   NULL,

        CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED (CustomerId),
        CONSTRAINT UQ_Customers_Email UNIQUE (Email)
    );

    CREATE NONCLUSTERED INDEX IX_Customers_Email ON dbo.Customers (Email);
    CREATE NONCLUSTERED INDEX IX_Customers_LastName ON dbo.Customers (LastName, FirstName);
END
GO

-- =============================================================================
-- Orders
-- =============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'dbo.Orders') AND type = 'U')
BEGIN
    CREATE TABLE dbo.Orders
    (
        OrderId       INT            IDENTITY(1,1) NOT NULL,
        OrderNumber   NVARCHAR(50)   NOT NULL,
        CustomerId    INT            NOT NULL,
        OrderDate     DATETIME2(7)   NOT NULL DEFAULT SYSUTCDATETIME(),
        Status        NVARCHAR(20)   NOT NULL DEFAULT 'Pending',
        SubTotal      DECIMAL(18,2)  NOT NULL DEFAULT 0,
        TaxAmount     DECIMAL(18,2)  NOT NULL DEFAULT 0,
        ShippingCost  DECIMAL(18,2)  NOT NULL DEFAULT 0,
        TotalAmount   DECIMAL(18,2)  NOT NULL DEFAULT 0,
        ShipToAddress NVARCHAR(500)  NULL,
        Notes         NVARCHAR(1000) NULL,
        CreatedDate   DATETIME2(7)   NOT NULL DEFAULT SYSUTCDATETIME(),
        ModifiedDate  DATETIME2(7)   NULL,

        CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderId),
        CONSTRAINT UQ_Orders_OrderNumber UNIQUE (OrderNumber),
        CONSTRAINT FK_Orders_Customers FOREIGN KEY (CustomerId)
            REFERENCES dbo.Customers (CustomerId),
        CONSTRAINT CK_Orders_Status CHECK (Status IN ('Pending', 'Processing', 'Shipped', 'Completed', 'Cancelled', 'Refunded')),
        CONSTRAINT CK_Orders_TotalAmount CHECK (TotalAmount >= 0)
    );

    CREATE NONCLUSTERED INDEX IX_Orders_CustomerId ON dbo.Orders (CustomerId);
    CREATE NONCLUSTERED INDEX IX_Orders_Status ON dbo.Orders (Status) INCLUDE (OrderDate, TotalAmount);
    CREATE NONCLUSTERED INDEX IX_Orders_OrderDate ON dbo.Orders (OrderDate DESC);
    CREATE NONCLUSTERED INDEX IX_Orders_OrderNumber ON dbo.Orders (OrderNumber);
END
GO

-- =============================================================================
-- Order Items
-- =============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'dbo.OrderItems') AND type = 'U')
BEGIN
    CREATE TABLE dbo.OrderItems
    (
        OrderItemId INT           IDENTITY(1,1) NOT NULL,
        OrderId     INT           NOT NULL,
        ProductId   INT           NOT NULL,
        Quantity    INT           NOT NULL,
        UnitPrice   DECIMAL(18,2) NOT NULL,
        Discount    DECIMAL(18,2) NOT NULL DEFAULT 0,
        LineTotal   AS (Quantity * UnitPrice - Discount) PERSISTED,

        CONSTRAINT PK_OrderItems PRIMARY KEY CLUSTERED (OrderItemId),
        CONSTRAINT FK_OrderItems_Orders FOREIGN KEY (OrderId)
            REFERENCES dbo.Orders (OrderId) ON DELETE CASCADE,
        CONSTRAINT FK_OrderItems_Products FOREIGN KEY (ProductId)
            REFERENCES dbo.Products (ProductId),
        CONSTRAINT CK_OrderItems_Quantity CHECK (Quantity > 0),
        CONSTRAINT CK_OrderItems_UnitPrice CHECK (UnitPrice >= 0)
    );

    CREATE NONCLUSTERED INDEX IX_OrderItems_OrderId ON dbo.OrderItems (OrderId);
    CREATE NONCLUSTERED INDEX IX_OrderItems_ProductId ON dbo.OrderItems (ProductId);
END
GO

-- =============================================================================
-- Inventory Log (audit trail for stock changes)
-- =============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'dbo.InventoryLog') AND type = 'U')
BEGIN
    CREATE TABLE dbo.InventoryLog
    (
        LogId          INT            IDENTITY(1,1) NOT NULL,
        ProductId      INT            NOT NULL,
        ChangeType     NVARCHAR(20)   NOT NULL,
        QuantityChange INT            NOT NULL,
        PreviousQty    INT            NOT NULL,
        NewQty         INT            NOT NULL,
        Reference      NVARCHAR(100)  NULL,
        Notes          NVARCHAR(500)  NULL,
        CreatedDate    DATETIME2(7)   NOT NULL DEFAULT SYSUTCDATETIME(),

        CONSTRAINT PK_InventoryLog PRIMARY KEY CLUSTERED (LogId),
        CONSTRAINT FK_InventoryLog_Products FOREIGN KEY (ProductId)
            REFERENCES dbo.Products (ProductId),
        CONSTRAINT CK_InventoryLog_ChangeType CHECK (ChangeType IN ('Receipt', 'Sale', 'Adjustment', 'Return', 'Transfer'))
    );

    CREATE NONCLUSTERED INDEX IX_InventoryLog_ProductId ON dbo.InventoryLog (ProductId, CreatedDate DESC);
END
GO

-- =============================================================================
-- Seed Data
-- =============================================================================

IF NOT EXISTS (SELECT 1 FROM dbo.Categories)
BEGIN
    INSERT INTO dbo.Categories (Name, Description) VALUES
        (N'Marine Hardware',    N'Anchors, cleats, fasteners, and deck hardware'),
        (N'Safety Equipment',   N'Life jackets, flares, fire extinguishers, and first aid'),
        (N'Electronics',        N'GPS, fish finders, radios, and navigation equipment'),
        (N'Maintenance',        N'Paints, cleaners, lubricants, and repair supplies'),
        (N'Apparel',            N'Foul weather gear, footwear, and accessories');
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.Products)
BEGIN
    INSERT INTO dbo.Products (SKU, Name, Description, Category, CategoryId, UnitPrice, StockQuantity, ReorderLevel) VALUES
        (N'MH-1001', N'Stainless Steel Cleat 8"',       N'Heavy-duty 316 stainless steel dock cleat',                 N'Marine Hardware',   1,   24.99, 150, 25),
        (N'MH-1002', N'Galvanized Anchor 15lb',          N'Hot-dip galvanized fluke anchor for boats up to 25ft',      N'Marine Hardware',   1,   89.99,  45, 10),
        (N'SE-2001', N'Type II Life Jacket - Adult',     N'USCG approved Type II PFD, universal adult size',           N'Safety Equipment',  2,   29.99, 200, 50),
        (N'SE-2002', N'Marine First Aid Kit',             N'Waterproof 150-piece first aid kit for marine use',         N'Safety Equipment',  2,   49.99,  80, 20),
        (N'EL-3001', N'Handheld VHF Radio',              N'Floating waterproof VHF marine radio with GPS',             N'Electronics',       3,  149.99,  60, 15),
        (N'EL-3002', N'7" Chartplotter GPS',             N'Touchscreen chartplotter with built-in maps',               N'Electronics',       3,  599.99,  25,  5),
        (N'MT-4001', N'Marine Bottom Paint - Gallon',    N'Antifouling copper-based bottom paint',                     N'Maintenance',       4,   74.99,  90, 20),
        (N'MT-4002', N'Teak Cleaner & Brightener Kit',   N'Two-part teak cleaning and restoration system',             N'Maintenance',       4,   34.99, 110, 30),
        (N'AP-5001', N'Offshore Sailing Jacket',         N'Breathable waterproof foul weather jacket',                 N'Apparel',           5,  189.99,  40, 10),
        (N'AP-5002', N'Non-Slip Deck Shoes',             N'Leather boat shoes with siped rubber sole',                 N'Apparel',           5,   79.99,  65, 15);
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.Customers)
BEGIN
    INSERT INTO dbo.Customers (FirstName, LastName, Email, Phone, AddressLine1, City, State, ZipCode) VALUES
        (N'James',   N'Mitchell',  N'j.mitchell@example.com',  N'555-0101', N'42 Marina Blvd',      N'Annapolis',    N'MD', N'21401'),
        (N'Sarah',   N'Chen',      N's.chen@example.com',      N'555-0102', N'118 Harbor Way',      N'Newport',      N'RI', N'02840'),
        (N'Robert',  N'Johnson',   N'r.johnson@example.com',   N'555-0103', N'7 Lighthouse Rd',     N'Mystic',       N'CT', N'06355');
END
GO

PRINT 'HarborRetailDB schema deployment completed successfully.';
GO
