using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using System.Net;
using System.Web.Http;

namespace HarborRetail.Api.Controllers
{
    [RoutePrefix("api/products")]
    public class ProductsController : ApiController
    {
        private readonly string _connectionString;

        public ProductsController()
        {
            _connectionString = ConfigurationManager.ConnectionStrings["HarborRetailDB"].ConnectionString;
        }

        /// <summary>
        /// Returns all active products.
        /// GET api/products
        /// </summary>
        [HttpGet]
        [Route("")]
        public IHttpActionResult GetAll()
        {
            var products = new List<ProductDto>();

            using (var connection = new SqlConnection(_connectionString))
            {
                connection.Open();
                const string query = @"
                    SELECT ProductId, SKU, Name, Description, Category,
                           UnitPrice, StockQuantity, IsActive, CreatedDate, ModifiedDate
                    FROM dbo.Products
                    WHERE IsActive = 1
                    ORDER BY Name";

                using (var command = new SqlCommand(query, connection))
                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        products.Add(MapProduct(reader));
                    }
                }
            }

            return Ok(products);
        }

        /// <summary>
        /// Returns a single product by ID.
        /// GET api/products/{id}
        /// </summary>
        [HttpGet]
        [Route("{id:int}")]
        public IHttpActionResult GetById(int id)
        {
            using (var connection = new SqlConnection(_connectionString))
            {
                connection.Open();
                const string query = @"
                    SELECT ProductId, SKU, Name, Description, Category,
                           UnitPrice, StockQuantity, IsActive, CreatedDate, ModifiedDate
                    FROM dbo.Products
                    WHERE ProductId = @ProductId";

                using (var command = new SqlCommand(query, connection))
                {
                    command.Parameters.AddWithValue("@ProductId", id);

                    using (var reader = command.ExecuteReader())
                    {
                        if (reader.Read())
                        {
                            return Ok(MapProduct(reader));
                        }
                    }
                }
            }

            return NotFound();
        }

        /// <summary>
        /// Returns products filtered by category.
        /// GET api/products/category/{category}
        /// </summary>
        [HttpGet]
        [Route("category/{category}")]
        public IHttpActionResult GetByCategory(string category)
        {
            var products = new List<ProductDto>();

            using (var connection = new SqlConnection(_connectionString))
            {
                connection.Open();
                const string query = @"
                    SELECT ProductId, SKU, Name, Description, Category,
                           UnitPrice, StockQuantity, IsActive, CreatedDate, ModifiedDate
                    FROM dbo.Products
                    WHERE Category = @Category AND IsActive = 1
                    ORDER BY Name";

                using (var command = new SqlCommand(query, connection))
                {
                    command.Parameters.AddWithValue("@Category", category);

                    using (var reader = command.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            products.Add(MapProduct(reader));
                        }
                    }
                }
            }

            return Ok(products);
        }

        /// <summary>
        /// Searches products by name or SKU.
        /// GET api/products/search?q={query}
        /// </summary>
        [HttpGet]
        [Route("search")]
        public IHttpActionResult Search([FromUri] string q)
        {
            if (string.IsNullOrWhiteSpace(q))
            {
                return BadRequest("Search query parameter 'q' is required.");
            }

            var products = new List<ProductDto>();

            using (var connection = new SqlConnection(_connectionString))
            {
                connection.Open();
                const string query = @"
                    SELECT ProductId, SKU, Name, Description, Category,
                           UnitPrice, StockQuantity, IsActive, CreatedDate, ModifiedDate
                    FROM dbo.Products
                    WHERE IsActive = 1
                      AND (Name LIKE @SearchTerm OR SKU LIKE @SearchTerm)
                    ORDER BY Name";

                using (var command = new SqlCommand(query, connection))
                {
                    command.Parameters.AddWithValue("@SearchTerm", "%" + q + "%");

                    using (var reader = command.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            products.Add(MapProduct(reader));
                        }
                    }
                }
            }

            return Ok(products);
        }

        /// <summary>
        /// Returns products with low stock (below threshold).
        /// GET api/products/low-stock?threshold={threshold}
        /// </summary>
        [HttpGet]
        [Route("low-stock")]
        public IHttpActionResult GetLowStock([FromUri] int threshold = 10)
        {
            var products = new List<ProductDto>();

            using (var connection = new SqlConnection(_connectionString))
            {
                connection.Open();
                const string query = @"
                    SELECT ProductId, SKU, Name, Description, Category,
                           UnitPrice, StockQuantity, IsActive, CreatedDate, ModifiedDate
                    FROM dbo.Products
                    WHERE IsActive = 1 AND StockQuantity < @Threshold
                    ORDER BY StockQuantity ASC";

                using (var command = new SqlCommand(query, connection))
                {
                    command.Parameters.AddWithValue("@Threshold", threshold);

                    using (var reader = command.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            products.Add(MapProduct(reader));
                        }
                    }
                }
            }

            return Ok(products);
        }

        private static ProductDto MapProduct(IDataReader reader)
        {
            return new ProductDto
            {
                ProductId = reader.GetInt32(reader.GetOrdinal("ProductId")),
                SKU = reader.GetString(reader.GetOrdinal("SKU")),
                Name = reader.GetString(reader.GetOrdinal("Name")),
                Description = reader.IsDBNull(reader.GetOrdinal("Description"))
                    ? null
                    : reader.GetString(reader.GetOrdinal("Description")),
                Category = reader.GetString(reader.GetOrdinal("Category")),
                UnitPrice = reader.GetDecimal(reader.GetOrdinal("UnitPrice")),
                StockQuantity = reader.GetInt32(reader.GetOrdinal("StockQuantity")),
                IsActive = reader.GetBoolean(reader.GetOrdinal("IsActive")),
                CreatedDate = reader.GetDateTime(reader.GetOrdinal("CreatedDate")),
                ModifiedDate = reader.IsDBNull(reader.GetOrdinal("ModifiedDate"))
                    ? (DateTime?)null
                    : reader.GetDateTime(reader.GetOrdinal("ModifiedDate"))
            };
        }
    }

    public class ProductDto
    {
        public int ProductId { get; set; }
        public string SKU { get; set; }
        public string Name { get; set; }
        public string Description { get; set; }
        public string Category { get; set; }
        public decimal UnitPrice { get; set; }
        public int StockQuantity { get; set; }
        public bool IsActive { get; set; }
        public DateTime CreatedDate { get; set; }
        public DateTime? ModifiedDate { get; set; }
    }
}
