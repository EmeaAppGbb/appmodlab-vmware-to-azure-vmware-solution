using System;
using System.Configuration;
using System.Data.SqlClient;
using System.Web.UI;

namespace HarborRetail.Web
{
    public partial class Default : Page
    {
        protected string StoreName { get; set; }
        protected int ProductCount { get; set; }
        protected int PendingOrderCount { get; set; }
        protected decimal TotalRevenue { get; set; }

        protected void Page_Load(object sender, EventArgs e)
        {
            if (!IsPostBack)
            {
                StoreName = "Harbor Retail";
                LoadDashboardMetrics();
            }
        }

        private void LoadDashboardMetrics()
        {
            string connectionString = ConfigurationManager.ConnectionStrings["HarborRetailDB"].ConnectionString;

            try
            {
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();

                    ProductCount = GetScalarInt(connection,
                        "SELECT COUNT(*) FROM dbo.Products WHERE IsActive = 1");

                    PendingOrderCount = GetScalarInt(connection,
                        "SELECT COUNT(*) FROM dbo.Orders WHERE Status = 'Pending'");

                    TotalRevenue = GetScalarDecimal(connection,
                        "SELECT ISNULL(SUM(TotalAmount), 0) FROM dbo.Orders WHERE Status = 'Completed'");
                }
            }
            catch (SqlException ex)
            {
                System.Diagnostics.Trace.TraceError(
                    "Database connection failed for HarborRetailDB: {0}", ex.Message);

                ProductCount = 0;
                PendingOrderCount = 0;
                TotalRevenue = 0;
            }
        }

        private static int GetScalarInt(SqlConnection connection, string query)
        {
            using (var command = new SqlCommand(query, connection))
            {
                object result = command.ExecuteScalar();
                return result != null && result != DBNull.Value ? Convert.ToInt32(result) : 0;
            }
        }

        private static decimal GetScalarDecimal(SqlConnection connection, string query)
        {
            using (var command = new SqlCommand(query, connection))
            {
                object result = command.ExecuteScalar();
                return result != null && result != DBNull.Value ? Convert.ToDecimal(result) : 0m;
            }
        }
    }
}
